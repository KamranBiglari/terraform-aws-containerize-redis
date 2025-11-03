#!/bin/bash

# Script to check Redis cluster health

set -e

: ${ECS_CLUSTER:?}
: ${ECS_SERVICE:?}
: ${AWS_REGION:?}

echo "==================================="
echo "Redis Cluster Health Check"
echo "==================================="

# Get running task count
RUNNING_COUNT=$(aws ecs describe-services \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" \
    --query 'services[0].runningCount' \
    --output text)

DESIRED_COUNT=$(aws ecs describe-services \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" \
    --query 'services[0].desiredCount' \
    --output text)

echo "Tasks: $RUNNING_COUNT / $DESIRED_COUNT"

# Get task IPs
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

IPS=$(aws ecs describe-tasks \
    --cluster "$ECS_CLUSTER" \
    --tasks $TASK_ARNS \
    --region "$AWS_REGION" \
    --query 'tasks[].attachments[].details[?name==`privateIPv4Address`].value' \
    --output text)

echo ""
echo "Redis Nodes:"
for ip in $IPS; do
    echo "  - $ip"
done

# Check first node's cluster status
FIRST_IP=$(echo "$IPS" | awk '{print $1}')

echo ""
echo "==================================="
echo "Cluster Info (from $FIRST_IP):"
echo "==================================="
redis-cli -h "$FIRST_IP" cluster info

echo ""
echo "==================================="
echo "Cluster Nodes (from $FIRST_IP):"
echo "==================================="
redis-cli -h "$FIRST_IP" cluster nodes

echo ""
echo "==================================="
echo "Node Health Check:"
echo "==================================="
for ip in $IPS; do
    PING_RESULT=$(redis-cli -h "$ip" ping 2>/dev/null || echo "FAILED")
    echo "  $ip: $PING_RESULT"
done
