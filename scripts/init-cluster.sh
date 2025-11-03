#!/bin/bash

set -e

# Redis Cluster Initialization Script
# This script discovers Redis nodes via ECS and initializes the cluster

# Required environment variables
: ${ECS_CLUSTER:?}
: ${ECS_SERVICE:?}
: ${MASTER_COUNT:=3}
: ${REPLICA_COUNT:=3}
: ${AWS_REGION:?}

REDIS_PORT=6379
TOTAL_NODES=$((MASTER_COUNT + REPLICA_COUNT))
REPLICAS_PER_MASTER=$((REPLICA_COUNT / MASTER_COUNT))

echo "==================================="
echo "Redis Cluster Initialization Script"
echo "==================================="
echo "ECS Cluster: $ECS_CLUSTER"
echo "ECS Service: $ECS_SERVICE"
echo "Masters: $MASTER_COUNT"
echo "Replicas: $REPLICA_COUNT"
echo "Replicas per Master: $REPLICAS_PER_MASTER"
echo "Total Nodes: $TOTAL_NODES"
echo "==================================="

# Function to get running task IPs
get_task_ips() {
    echo "Discovering Redis node IPs..."

    # Get task ARNs
    TASK_ARNS=$(aws ecs list-tasks \
        --cluster "$ECS_CLUSTER" \
        --service-name "$ECS_SERVICE" \
        --region "$AWS_REGION" \
        --desired-status RUNNING \
        --query 'taskArns[]' \
        --output text)

    if [ -z "$TASK_ARNS" ]; then
        echo "ERROR: No running tasks found"
        exit 1
    fi

    # Get task details and extract IPs
    IPS=$(aws ecs describe-tasks \
        --cluster "$ECS_CLUSTER" \
        --tasks $TASK_ARNS \
        --region "$AWS_REGION" \
        --query 'tasks[].attachments[].details[?name==`privateIPv4Address`].value' \
        --output text)

    echo "$IPS"
}

# Function to check if cluster is already initialized
is_cluster_initialized() {
    local node_ip=$1

    echo "Checking if cluster is already initialized on $node_ip..."

    CLUSTER_INFO=$(redis-cli -h "$node_ip" -p "$REDIS_PORT" cluster info 2>/dev/null || echo "")

    if echo "$CLUSTER_INFO" | grep -q "cluster_state:ok"; then
        echo "Cluster is already initialized"
        return 0
    fi

    if echo "$CLUSTER_INFO" | grep -q "cluster_known_nodes"; then
        KNOWN_NODES=$(echo "$CLUSTER_INFO" | grep cluster_known_nodes | cut -d: -f2 | tr -d '\r')
        if [ "$KNOWN_NODES" -gt 1 ]; then
            echo "Cluster already has $KNOWN_NODES nodes"
            return 0
        fi
    fi

    echo "Cluster is not initialized"
    return 1
}

# Function to wait for all nodes to be running
wait_for_nodes() {
    local max_wait=300  # 5 minutes
    local elapsed=0

    echo "Waiting for all $TOTAL_NODES nodes to be running..."

    while [ $elapsed -lt $max_wait ]; do
        RUNNING_COUNT=$(aws ecs describe-services \
            --cluster "$ECS_CLUSTER" \
            --services "$ECS_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].runningCount' \
            --output text)

        echo "Running tasks: $RUNNING_COUNT / $TOTAL_NODES"

        if [ "$RUNNING_COUNT" -eq "$TOTAL_NODES" ]; then
            echo "All nodes are running. Waiting 30 seconds for health checks..."
            sleep 30
            return 0
        fi

        sleep 10
        elapsed=$((elapsed + 10))
    done

    echo "ERROR: Timeout waiting for nodes"
    return 1
}

# Function to create the cluster
create_cluster() {
    local ips=$1

    echo "Building node list..."
    NODES=""
    for ip in $ips; do
        NODES="$NODES ${ip}:${REDIS_PORT}"
    done

    echo "Nodes: $NODES"

    echo "Creating Redis cluster..."
    redis-cli --cluster create $NODES \
        --cluster-replicas "$REPLICAS_PER_MASTER" \
        --cluster-yes

    if [ $? -ne 0 ]; then
        echo "ERROR: Cluster creation failed"
        exit 1
    fi

    echo "Cluster created successfully!"

    # Verify cluster
    FIRST_IP=$(echo "$ips" | awk '{print $1}')
    echo ""
    echo "Verifying cluster on $FIRST_IP..."
    redis-cli -h "$FIRST_IP" -p "$REDIS_PORT" cluster info
    echo ""
    redis-cli -h "$FIRST_IP" -p "$REDIS_PORT" cluster nodes
}

# Main execution
main() {
    # Wait for all nodes to be running
    if ! wait_for_nodes; then
        exit 1
    fi

    # Get node IPs
    NODE_IPS=$(get_task_ips)
    NODE_COUNT=$(echo "$NODE_IPS" | wc -w)

    echo "Found $NODE_COUNT nodes:"
    echo "$NODE_IPS"

    if [ "$NODE_COUNT" -lt "$TOTAL_NODES" ]; then
        echo "ERROR: Expected $TOTAL_NODES nodes but found $NODE_COUNT"
        exit 1
    fi

    # Check if already initialized
    FIRST_IP=$(echo "$NODE_IPS" | awk '{print $1}')
    if is_cluster_initialized "$FIRST_IP"; then
        echo "Cluster is already running. Nothing to do."
        exit 0
    fi

    # Create cluster
    create_cluster "$NODE_IPS"

    echo ""
    echo "==================================="
    echo "Redis cluster initialization complete!"
    echo "==================================="
}

# Run main function
main
