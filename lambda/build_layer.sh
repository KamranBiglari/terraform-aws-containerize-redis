#!/bin/bash

# Build Lambda Layer with redis-py dependency
# This script creates a Lambda layer with the required Python packages

set -e

# Work from the module root regardless of where this is invoked from: Terraform
# runs it with working_dir = path.module, but it is also run by hand.
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYER_DIR="${MODULE_DIR}/lambda/layer/python"

# Pick an interpreter that actually runs. Checking PATH alone is not enough: on
# Windows, python3 is usually the Microsoft Store alias stub, which resolves but
# fails on every invocation.
PYTHON=""
for candidate in python3 python "py -3"; do
    if $candidate -c "import sys" >/dev/null 2>&1; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "ERROR: a working python3 (or python) is required to build the Lambda layer, but none was found on PATH." >&2
    echo "       Install Python 3, or point lambda_layer_build_interpreter at a shell that has one." >&2
    exit 1
fi

echo "Building Lambda layer with redis-py using $PYTHON..."

# Start from a clean directory so removed dependencies do not linger in the layer
rm -rf "${MODULE_DIR}/lambda/layer"
mkdir -p "${LAYER_DIR}"

# Install dependencies
$PYTHON -m pip install -r "${MODULE_DIR}/lambda/requirements.txt" -t "${LAYER_DIR}/" --upgrade

echo "Lambda layer built successfully at ${MODULE_DIR}/lambda/layer/"
echo "Contents:"
ls -la "${LAYER_DIR}/"
