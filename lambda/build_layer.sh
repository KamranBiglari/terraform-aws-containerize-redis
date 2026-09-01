#!/bin/bash

# Build the Lambda layer holding the Python dependencies in lambda/requirements.txt.
#
# Docker is used by default: it produces Linux/x86_64 wheels matching the Lambda
# runtime regardless of the machine running Terraform, and needs no Python on the
# host. A local pip install is available as a fallback for environments without
# Docker - it relies on the host's Python and, off Linux/x86_64, can install
# wheels the runtime cannot load.
#
#   LAYER_BUILD_METHOD  auto (default) | docker | python
#   LAYER_BUILD_IMAGE   build image for the docker method

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAMBDA_DIR="${MODULE_DIR}/lambda"
LAYER_DIR="${LAMBDA_DIR}/layer/python"

METHOD="${LAYER_BUILD_METHOD:-auto}"
IMAGE="${LAYER_BUILD_IMAGE:-public.ecr.aws/sam/build-python3.11}"

have_docker() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# Prints an interpreter that has pip, or nothing. Checking PATH is not enough: on
# Windows python3 is usually the Microsoft Store alias stub, and plenty of Linux
# images ship python3 with no pip module at all.
find_python() {
    local candidate
    for candidate in python3 python "py -3"; do
        if $candidate -m pip --version >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

build_with_docker() {
    local host_lambda_dir="${LAMBDA_DIR}"
    local user_args=()

    # Docker Desktop needs a Windows-style path, and MSYS must not rewrite the
    # container-side paths of the arguments below.
    if command -v cygpath >/dev/null 2>&1; then
        host_lambda_dir="$(cygpath -w "${LAMBDA_DIR}")"
        export MSYS_NO_PATHCONV=1
    fi

    # Keep the built files owned by the invoking user rather than root
    case "$(uname -s)" in
        Linux* | Darwin*) user_args=(--user "$(id -u):$(id -g)") ;;
    esac

    echo "Building Lambda layer with ${IMAGE}..."

    # --platform pins x86_64: the Lambda function runs on the default
    # architecture, and an arm64 host would otherwise produce unloadable wheels.
    docker run --rm \
        --platform linux/amd64 \
        "${user_args[@]}" \
        -e HOME=/tmp \
        -v "${host_lambda_dir}:/build" \
        --entrypoint /bin/sh \
        "${IMAGE}" \
        -c "pip install -r /build/requirements.txt -t /build/layer/python --upgrade --no-cache-dir"
}

build_with_python() {
    local python
    if ! python="$(find_python)"; then
        return 1
    fi

    echo "Building Lambda layer with ${python} (no Docker available)..."
    echo "WARNING: dependencies are built for this machine. On anything other than" >&2
    echo "         Linux/x86_64 the layer may not load in Lambda." >&2

    $python -m pip install -r "${LAMBDA_DIR}/requirements.txt" -t "${LAYER_DIR}/" --upgrade
}

# Start from a clean directory so removed dependencies do not linger in the layer
rm -rf "${LAMBDA_DIR}/layer"
mkdir -p "${LAYER_DIR}"

case "${METHOD}" in
    docker)
        if ! have_docker; then
            echo "ERROR: lambda_layer_build_method is \"docker\" but Docker is not available." >&2
            echo "       Start Docker, or set lambda_layer_build_method to \"auto\" or \"python\"." >&2
            exit 1
        fi
        build_with_docker
        ;;
    python)
        if ! build_with_python; then
            echo "ERROR: lambda_layer_build_method is \"python\" but no Python with pip was found on PATH." >&2
            exit 1
        fi
        ;;
    auto)
        if have_docker; then
            build_with_docker
        elif build_with_python; then
            :
        else
            echo "ERROR: cannot build the Lambda layer. Docker is not available and no" >&2
            echo "       Python with pip was found on PATH. Install either one, or set" >&2
            echo "       enable_cluster_init = false to skip the initialization Lambda." >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unknown LAYER_BUILD_METHOD \"${METHOD}\" (expected auto, docker or python)." >&2
        exit 1
        ;;
esac

echo "Lambda layer built successfully at ${LAMBDA_DIR}/layer/"
ls "${LAYER_DIR}/" | head -20
