import os
import json
import time
import boto3
from typing import List, Dict

ecs_client = boto3.client('ecs')
sd_client = boto3.client('servicediscovery')

def handler(event, context):
    """
    Lambda handler to initialize Redis cluster after all nodes are running.
    This function discovers all Redis nodes via CloudMap and runs the cluster create command.
    """

    print(f"Event: {json.dumps(event)}")

    # Get environment variables
    cluster_arn = os.environ['ECS_CLUSTER_ARN']
    service_name = os.environ['ECS_SERVICE_NAME']
    master_count = int(os.environ['REDIS_MASTER_COUNT'])
    replica_count = int(os.environ['REDIS_REPLICA_COUNT'])
    namespace = os.environ['CLOUDMAP_NAMESPACE']
    service = os.environ['CLOUDMAP_SERVICE']

    total_nodes = master_count + replica_count
    replicas_per_master = replica_count // master_count if master_count > 0 else 0

    print(f"Cluster configuration: {master_count} masters, {replica_count} replicas ({replicas_per_master} per master)")

    try:
        # Wait for all tasks to be running and healthy
        print("Checking ECS service status...")
        if not wait_for_service_stable(cluster_arn, service_name, total_nodes):
            return {
                'statusCode': 500,
                'body': json.dumps('ECS service did not stabilize in time')
            }

        # Get all running task IPs
        print("Discovering Redis node IPs...")
        node_ips = get_redis_node_ips(cluster_arn, service_name)

        if len(node_ips) < total_nodes:
            print(f"WARNING: Expected {total_nodes} nodes but found {len(node_ips)}")
            return {
                'statusCode': 500,
                'body': json.dumps(f'Not enough nodes running. Expected {total_nodes}, found {len(node_ips)}')
            }

        print(f"Found {len(node_ips)} Redis nodes: {node_ips}")

        # Check if cluster is already initialized
        if is_cluster_initialized(node_ips[0]):
            print("Redis cluster is already initialized")
            return {
                'statusCode': 200,
                'body': json.dumps('Cluster already initialized')
            }

        # Create cluster using the first node as the coordinator
        print("Initializing Redis cluster...")
        create_cluster(node_ips, master_count, replicas_per_master)

        print("Redis cluster initialized successfully!")
        return {
            'statusCode': 200,
            'body': json.dumps('Cluster initialized successfully')
        }

    except Exception as e:
        print(f"Error initializing cluster: {str(e)}")
        import traceback
        traceback.print_exc()
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }


def wait_for_service_stable(cluster_arn: str, service_name: str, expected_count: int, max_wait: int = 600) -> bool:
    """Wait for ECS service to have all tasks running"""
    start_time = time.time()

    while time.time() - start_time < max_wait:
        response = ecs_client.describe_services(
            cluster=cluster_arn,
            services=[service_name]
        )

        if not response['services']:
            print("Service not found")
            time.sleep(10)
            continue

        service = response['services'][0]
        running_count = service['runningCount']
        desired_count = service['desiredCount']

        print(f"Service status: running={running_count}, desired={desired_count}")

        if running_count == desired_count == expected_count:
            # Wait an additional 30 seconds for health checks
            print("All tasks running, waiting for health checks...")
            time.sleep(30)
            return True

        time.sleep(10)

    return False


def get_redis_node_ips(cluster_arn: str, service_name: str) -> List[str]:
    """Get IP addresses of all running Redis tasks"""

    # List all tasks in the service
    task_arns = []
    paginator = ecs_client.get_paginator('list_tasks')

    for page in paginator.paginate(cluster=cluster_arn, serviceName=service_name):
        task_arns.extend(page['taskArns'])

    if not task_arns:
        return []

    # Describe tasks to get ENI information
    response = ecs_client.describe_tasks(cluster=cluster_arn, tasks=task_arns)

    ips = []
    for task in response['tasks']:
        # Get private IP from task
        for attachment in task.get('attachments', []):
            if attachment['type'] == 'ElasticNetworkInterface':
                for detail in attachment['details']:
                    if detail['name'] == 'privateIPv4Address':
                        ips.append(detail['value'])
                        break

    return ips


def is_cluster_initialized(node_ip: str) -> bool:
    """Check if Redis cluster is already initialized by checking cluster info"""
    import subprocess

    try:
        result = subprocess.run(
            ['redis-cli', '-h', node_ip, 'cluster', 'info'],
            capture_output=True,
            text=True,
            timeout=5
        )

        # If cluster is initialized, cluster_state will be ok
        if 'cluster_state:ok' in result.stdout:
            return True

        # Check if cluster knows about multiple nodes
        if 'cluster_known_nodes' in result.stdout:
            for line in result.stdout.split('\n'):
                if line.startswith('cluster_known_nodes:'):
                    known_nodes = int(line.split(':')[1])
                    if known_nodes > 1:
                        return True

        return False

    except Exception as e:
        print(f"Error checking cluster status: {e}")
        return False


def create_cluster(node_ips: List[str], master_count: int, replicas_per_master: int):
    """Create Redis cluster using redis-cli"""
    import subprocess

    # Build node list with port
    nodes = [f"{ip}:6379" for ip in node_ips]

    # Build redis-cli command
    cmd = [
        'redis-cli',
        '--cluster', 'create'
    ] + nodes + [
        '--cluster-replicas', str(replicas_per_master),
        '--cluster-yes'  # Auto-accept configuration
    ]

    print(f"Running command: {' '.join(cmd)}")

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120
        )

        print(f"STDOUT: {result.stdout}")
        print(f"STDERR: {result.stderr}")

        if result.returncode != 0:
            raise Exception(f"Cluster creation failed: {result.stderr}")

        # Verify cluster is created
        time.sleep(5)
        verify_result = subprocess.run(
            ['redis-cli', '-h', node_ips[0], 'cluster', 'info'],
            capture_output=True,
            text=True,
            timeout=5
        )

        print(f"Cluster verification: {verify_result.stdout}")

        if 'cluster_state:ok' not in verify_result.stdout:
            raise Exception("Cluster creation verification failed")

    except subprocess.TimeoutExpired:
        raise Exception("Cluster creation timed out")
    except Exception as e:
        raise Exception(f"Failed to create cluster: {str(e)}")
