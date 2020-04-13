#!/bin/bash

set -e

build_env() {
    cat <<"EOF"
export REGISTRY_USERNAME="${REGISTRY_USERNAME:-danfaizer}"
export REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
export REGISTRY_REPO_PATH="${REGISTRY_REPO_PATH:-https://registry.hub.docker.com/v2/repositories/}"
export REGISTRY_API_SLEEP="${REGISTRY_API_SLEEP:-1}"
EOF
}

########################
# Check if a check with specific tags has been already pushed.
# Arguments:
#   $@ - List of check tags
# Returns:
#   Boolean
is_pushed() {
    local -r tags=("$@")
    check_id_published=false
    check_dependencies_id=false

    for tag in $tags; do
        if [[ $tag == *".id."* ]]; then
            curl -L --silent "$REGISTRY_REPO_PATH/$REGISTRY_USERNAME/vulcan-checks/tags/$tag" | jq '.message' -e > /dev/null 2>&1
            if [ $? -gt 0 ]; then
                check_id_published=true
            fi
        fi
        if [[ $tag == *".dep."* ]]; then
            curl -L --silent "$REGISTRY_REPO_PATH/$REGISTRY_USERNAME/vulcan-checks/tags/$tag" | jq '.message' -e > /dev/null 2>&1
            if [ $? -gt 0 ]; then
                check_dependencies_id=true
            fi
        fi
    done
    # "Rate-limit" registry API requests.
    sleep $REGISTRY_API_SLEEP
    if [[ $check_id_published = true && $check_dependencies_id = true ]]; then
        echo true
    else
        echo false
    fi
}

########################
# Generates a list of tags for a check.
# Arguments:
#   $1 - Check name
#   $2 - Check commit id
#   $3 - Greater (check or dependencies timestamp)
#   $4 - Dependencies commit id
#   $5 - Version (master or experimental)
# Returns:
#   Array
generate_check_tags() {
    local -r check="${1}"
    local -r check_id="${2}"
    local -r check_ts="${3}"
    local -r dependencies_id="${4}"
    local -r version="${5}"
    tags=("$check.id.${check_id}" "$check.ts.${check_ts}" "$check.dep.${dependencies_id}" "$check.${version}")
    echo "${tags[@]}"
}

########################
# Check if current git folder is master or a branch.
# Returns master or experimental.
# Arguments:
#   None
# Returns:
#   String
version() {
    local -r branch=$(git_execute rev-parse --abbrev-ref HEAD)
    if [ "$branch" = "master" ]; then
        echo "master"
    else
        echo "experimental"
    fi
}

########################
# Returns latest commit id for a given file or folder path.
# Arguments:
#   $1 - Path to object (file or directory)
# Returns:
#   String
git_commit_id() {
    local -r object_path="${1:?object argument required}"
    git_execute --no-pager log -1 --pretty=tformat:"%h" "${object_path}"
}

########################
# Returns latest timestamp for a given file or folder path.
# Arguments:
#   $1 - Path to object (file or directory)
# Returns:
#   String
git_timestamp() {
    local -r object_path="${1:?object argument required}"
    git_execute --no-pager log -1 --pretty=tformat:"%ct" "${object_path}"
}

########################
# Execute an arbitrary git command
# Arguments:
#   $@ - Command to execute
# Returns:
#   String
git_execute() {
    local -r args=("$@")
    local exec
    exec=$(command -v git)

    "${exec}" "${args[@]}"
}

build_and_push() {
    # Login to docker registry.
    echo ${REGISTRY_PASSWORD} | docker login -u ${REGISTRY_USERNAME} --password-stdin
    if [ $? -ne 0 ]; then
        echo "ERROR login docker registry. Exit."
        # Don't want to fail build.
        exit 0
    fi
    version=$(version)

    go mod download

    dependencies_ts=$(git_timestamp "go.mod")
    dependencies_id=$(git_commit_id "go.mod")

    cd cmd
    echo "Start build and push process: $(date)"
    for check in $(ls -d *); do
        check_ts=$(git_timestamp "${check}")
        check_id=$(git_commit_id "${check}")

        # Verify if check was pushed by code or dependency update.
        if [ "$dependencies_ts" -gt "$check_ts" ]; then
            check_ts="$dependencies_ts"
        fi
        # Generate check tag array.
        tags=$(generate_check_tags "$check" "$check_id" "$check_ts" "$dependencies_id" "$version")
        # Verify if check has been already pushed.
        skip_push=$(is_pushed "${tags[@]}")
        if [ "$skip_push" = true ]; then
            echo "Skip check: $check - commit id: $check_id - dependencies commit id: $dependencies_id"
            continue
        fi
        cd ${check}
        # Build go binray.
        CGO_ENABLED=0 go build .
        # Build docker image.
        docker build --quiet . -t "$REGISTRY_USERNAME/vulcan-checks:${check}" > /dev/null
        if [ $? -ne 0 ]; then
            echo "ERROR building check: $check - commit id: $check_id - dependencies commit id: $dependencies_id"
            continue
        fi
        for tag in $tags; do
            # Build docker image.
            docker tag "$REGISTRY_USERNAME/vulcan-checks:${check}" "$REGISTRY_USERNAME/vulcan-checks:${tag}" > /dev/null
            if [ $? -ne 0 ]; then
                echo "ERROR tagging check: $check - commit id: $check_id - dependencies commit id: $dependencies_id"
                continue
            fi
        done
        docker push "$REGISTRY_USERNAME/vulcan-checks:${check}" > /dev/null
        if [ $? -ne 0 ]; then
            echo "ERROR pushing check: $check - commit id: $check_id - dependencies commit id: $dependencies_id"
            continue
        fi
        echo "Pushed check: $check - commit id: $check_id - dependencies commit id: $dependencies_id"
        cd - > /dev/null 2>&1
    done
    echo "Finish build and push process: $(date)"
}

eval "$(build_env)"
build_and_push
