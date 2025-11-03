#!/bin/bash

# Build Lambda Layer with redis-py dependency
# This script creates a Lambda layer with the required Python packages

set -e

echo "Building Lambda layer with redis-py..."

# Create layer directory structure
mkdir -p lambda/layer/python

# Install dependencies
pip install -r lambda/requirements.txt -t lambda/layer/python/ --upgrade

echo "Lambda layer built successfully at lambda/layer/"
echo "Contents:"
ls -la lambda/layer/python/
