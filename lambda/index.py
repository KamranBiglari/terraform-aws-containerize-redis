import os
import json
import time
import boto3
import subprocess
from typing import List, Dict, Tuple

ecs_client = boto3.client('ecs')
ssm_client = boto3.client('ssm')
ec2_client = boto3.client('ec2')

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
    redis_port = int(os.environ.get('REDIS_PORT', '6379'))
    redis_cluster_port = int(os.environ.get('REDIS_CLUSTER_PORT', '16379'))

    security_group_id = os.environ['SECURITY_GROUP_ID']
    client_rule_desc = os.environ.get('CLIENT_RULE_DESC', 'redis client access')
    allowed_cidr_blocks = [
        cidr for cidr in os.environ.get('ALLOWED_CIDR_BLOCKS', '').split(',') if cidr
    ]

    total_nodes = master_count + replica_count
    replicas_per_master = replica_count // master_count if master_count > 0 else 0

    print(f"Cluster configuration: {master_count} masters, {replica_count} replicas ({replicas_per_master} per master)")

    try:
        # A cluster that is already healthy needs no work, and must not have its
        # client access interrupted.
        print("Discovering Redis nodes...")
        try:
            task_arns, node_ips = get_redis_nodes(cluster_arn, service_name)
        except Exception as e:
            print(f"Could not discover nodes yet: {e}")
            task_arns, node_ips = [], []

        if node_ips and is_cluster_initialized(node_ips[0], redis_port):
            print("Redis cluster is already initialized")
            authorize_client_access(security_group_id, allowed_cidr_blocks, redis_port, client_rule_desc)
            return {
                'statusCode': 200,
                'body': json.dumps('Cluster already initialized')
            }

        # The nodes are unclustered - either a first deployment or a restart that
        # replaced every task. Keep clients out until the cluster is formed: a
        # single client write turns a node into one Redis refuses to cluster.
        revoke_client_access(security_group_id, client_rule_desc)

        # Wait for all tasks to be running and healthy
        print("Checking ECS service status...")
        if not wait_for_service_stable(cluster_arn, service_name, total_nodes):
            raise RuntimeError('ECS service did not stabilize in time')

        # Get all running tasks and their IPs
        print("Discovering Redis nodes...")
        task_arns, node_ips = get_redis_nodes(cluster_arn, service_name)

        if len(node_ips) < total_nodes:
            raise RuntimeError(
                f'Not enough nodes running. Expected {total_nodes}, found {len(node_ips)}'
            )

        print(f"Found {len(node_ips)} Redis nodes: {node_ips}")
        print(f"Task ARNs: {task_arns}")

        # Create cluster by connecting directly to Redis nodes
        print("Initializing Redis cluster...")
        create_cluster_direct(node_ips, replicas_per_master, redis_port)

        # Cluster is healthy - let clients back in
        authorize_client_access(security_group_id, allowed_cidr_blocks, redis_port, client_rule_desc)

        print("Redis cluster initialized successfully!")
        return {
            'statusCode': 200,
            'body': json.dumps('Cluster initialized successfully')
        }

    except Exception as e:
        print(f"Error initializing cluster: {str(e)}")
        import traceback
        traceback.print_exc()
        # Client access stays revoked: an unclustered or half-clustered fleet must
        # not be reachable, and the next steady-state event retries from scratch.
        raise


def revoke_client_access(security_group_id: str, description: str):
    """
    Remove the client ingress rules this function owns.

    Rules are matched on their description, so rules added by anything else on the
    same security group - including the cluster's own node-to-node rules - are
    left alone.
    """
    response = ec2_client.describe_security_group_rules(
        Filters=[{'Name': 'group-id', 'Values': [security_group_id]}]
    )

    rule_ids = [
        rule['SecurityGroupRuleId']
        for rule in response.get('SecurityGroupRules', [])
        if not rule.get('IsEgress') and rule.get('Description') == description
    ]

    if not rule_ids:
        print("No client access rules to revoke")
        return

    print(f"Revoking {len(rule_ids)} client access rule(s) on {security_group_id}")
    ec2_client.revoke_security_group_ingress(
        GroupId=security_group_id,
        SecurityGroupRuleIds=rule_ids,
    )


def authorize_client_access(security_group_id: str, cidr_blocks: List[str], redis_port: int, description: str):
    """Open the Redis port to the allowed CIDR blocks now that the cluster is healthy."""
    if not cidr_blocks:
        print("No allowed CIDR blocks configured; leaving client access closed")
        return

    print(f"Authorizing client access from {cidr_blocks} on {security_group_id}")

    try:
        ec2_client.authorize_security_group_ingress(
            GroupId=security_group_id,
            IpPermissions=[{
                'IpProtocol': 'tcp',
                'FromPort': redis_port,
                'ToPort': redis_port,
                'IpRanges': [
                    {'CidrIp': cidr, 'Description': description} for cidr in cidr_blocks
                ],
            }],
        )
    except ec2_client.exceptions.ClientError as e:
        # Rules that are already there are fine - the end state is what matters.
        if e.response['Error']['Code'] != 'InvalidPermission.Duplicate':
            raise
        print("Client access rules already present")


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


def get_redis_nodes(cluster_arn: str, service_name: str) -> Tuple[List[str], List[str]]:
    """Get task ARNs and IP addresses of all running Redis tasks"""

    # List all tasks in the service
    task_arns = []
    paginator = ecs_client.get_paginator('list_tasks')

    for page in paginator.paginate(cluster=cluster_arn, serviceName=service_name):
        task_arns.extend(page['taskArns'])

    if not task_arns:
        return [], []

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

    return task_arns, ips


def is_cluster_initialized(node_ip: str, redis_port: int = 6379) -> bool:
    """
    Check if Redis cluster is already initialized by connecting directly to a node.
    Lambda is in the same VPC, so it can reach the nodes directly.
    """
    try:
        import redis

        print(f"Checking cluster status on {node_ip}:{redis_port}...")

        # Connect to the node
        node_conn = redis.Redis(host=node_ip, port=redis_port, decode_responses=True, socket_connect_timeout=5)

        # Try to get cluster info
        cluster_info = node_conn.execute_command('CLUSTER', 'INFO')

        # Convert to string if bytes
        if isinstance(cluster_info, bytes):
            cluster_info_str = cluster_info.decode('utf-8')
        else:
            cluster_info_str = str(cluster_info)

        print(f"Existing cluster info: {cluster_info_str}")

        # Check if cluster is properly initialized (state:ok and all slots assigned)
        if 'cluster_state:ok' in cluster_info_str and 'cluster_slots_assigned:16384' in cluster_info_str:
            print("Cluster is already fully initialized")
            return True

        print("Cluster is not fully initialized")
        return False

    except Exception as e:
        print(f"Error checking cluster status: {e}")
        return False


def parse_cluster_info(raw) -> Dict[str, str]:
    """Parse the key:value lines returned by CLUSTER INFO into a dict."""
    text = raw.decode('utf-8') if isinstance(raw, bytes) else str(raw)

    info = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or ':' not in line:
            continue
        key, value = line.split(':', 1)
        info[key.strip()] = value.strip()

    return info


def assert_nodes_empty(node_ips: List[str], redis_port: int):
    """
    Verify every node is a fresh, empty instance before forming the cluster.

    Redis refuses to create a cluster from nodes that already contain keys or
    already know about other nodes, and CLUSTER RESET will not clear a master
    that holds keys. Failing here with a clear message beats failing halfway
    through CLUSTER MEET with a cluster in a half-formed state.
    """
    import redis

    problems = []

    for ip in node_ips:
        node_conn = redis.Redis(host=ip, port=redis_port, decode_responses=True, socket_connect_timeout=5)

        db_size = int(node_conn.execute_command('DBSIZE'))
        info = parse_cluster_info(node_conn.execute_command('CLUSTER', 'INFO'))
        known_nodes = int(info.get('cluster_known_nodes', '1'))
        slots_assigned = int(info.get('cluster_slots_assigned', '0'))

        print(
            f"Node {ip}:{redis_port} - keys: {db_size}, known nodes: {known_nodes}, "
            f"slots assigned: {slots_assigned}"
        )

        if db_size > 0:
            problems.append(
                f"{ip}:{redis_port} holds {db_size} key(s) in database 0"
            )
        elif known_nodes > 1 or slots_assigned > 0:
            # No keys, so CLUSTER RESET HARD can clean this up on the next step.
            print(f"Node {ip} carries stale cluster state but is empty; it will be reset")

    if problems:
        raise RuntimeError(
            "Refusing to create the cluster because some nodes are not empty: "
            + "; ".join(problems)
            + ". Redis can only form a cluster from empty nodes. Flush the data "
              "(or replace the tasks) and re-run the initialization."
        )

    print(f"All {len(node_ips)} nodes are empty and ready to be clustered")


def create_cluster_direct(node_ips: List[str], replicas_per_master: int, redis_port: int = 6379):
    """
    Create Redis cluster by using Python redis library to connect directly to nodes.
    Lambda is in the same VPC as the Redis tasks, so it can reach them.
    """
    try:
        import redis

        print(f"Creating cluster with nodes: {node_ips}")
        print(f"Replicas per master: {replicas_per_master}")
        print(f"Redis port: {redis_port}")

        # Refuse to touch nodes that already hold data
        assert_nodes_empty(node_ips, redis_port)

        # First, reset all nodes to clean state in case of previous failed attempts
        print("Resetting all nodes to clean state...")
        for ip in node_ips:
            try:
                node_conn = redis.Redis(host=ip, port=redis_port, decode_responses=True, socket_connect_timeout=5)
                # Check if node has any cluster configuration
                cluster_info = node_conn.execute_command('CLUSTER', 'INFO')
                cluster_info_str = cluster_info.decode('utf-8') if isinstance(cluster_info, bytes) else str(cluster_info)

                # Only reset if cluster is not in a good state
                if 'cluster_state:ok' not in cluster_info_str or 'cluster_slots_assigned:16384' not in cluster_info_str:
                    print(f"Resetting node {ip}...")
                    node_conn.execute_command('CLUSTER', 'RESET', 'HARD')
                    time.sleep(1)
                else:
                    print(f"Node {ip} is already in good state, skipping reset")
            except Exception as e:
                print(f"Warning: Could not reset node {ip}: {e}")
                # Continue anyway, might be a new node

        print("All nodes reset. Verifying nodes are in a clean state...")

        for ip in node_ips:
            node_conn = redis.Redis(host=ip, port=redis_port, decode_responses=True, socket_connect_timeout=5)
            info = parse_cluster_info(node_conn.execute_command('CLUSTER', 'INFO'))
            known_nodes = int(info.get('cluster_known_nodes', '1'))
            slots_assigned = int(info.get('cluster_slots_assigned', '0'))

            if known_nodes > 1 or slots_assigned > 0:
                raise RuntimeError(
                    f"Node {ip}:{redis_port} still has cluster state after reset "
                    f"(known nodes: {known_nodes}, slots assigned: {slots_assigned}). "
                    "Replace the tasks and re-run the initialization."
                )

        print("All nodes clean. Starting cluster creation...")

        # Build node list
        nodes = [{'host': ip, 'port': redis_port} for ip in node_ips]

        # Use redis-py-cluster or direct redis commands
        # First, let's try to create the cluster using CLUSTER MEET commands

        # Connect to first node as coordinator
        coordinator = redis.Redis(host=node_ips[0], port=redis_port, decode_responses=True)

        # Make all nodes meet each other
        print("Making nodes meet each other...")
        for ip in node_ips[1:]:
            coordinator.execute_command('CLUSTER', 'MEET', ip, redis_port)
            print(f"Node {node_ips[0]} met {ip}")
            time.sleep(1)

        # Wait for gossip protocol to propagate
        print("Waiting for cluster gossip to propagate...")
        time.sleep(10)

        # Now assign slots
        print("Assigning hash slots...")
        master_count = len(node_ips) - (len(node_ips) * replicas_per_master // (replicas_per_master + 1))
        slots_per_master = 16384 // master_count

        for i in range(master_count):
            start_slot = i * slots_per_master
            end_slot = (i + 1) * slots_per_master - 1 if i < master_count - 1 else 16383

            node_conn = redis.Redis(host=node_ips[i], port=redis_port, decode_responses=True)
            node_id = node_conn.execute_command('CLUSTER', 'MYID')

            print(f"Assigning slots {start_slot}-{end_slot} to node {node_ips[i]}:{redis_port} (ID: {node_id})")

            # Assign slots in batches for better performance
            batch_size = 100
            for slot_start in range(start_slot, end_slot + 1, batch_size):
                slot_end = min(slot_start + batch_size - 1, end_slot)
                slots = list(range(slot_start, slot_end + 1))
                node_conn.execute_command('CLUSTER', 'ADDSLOTS', *slots)

        # Set up replication
        if replicas_per_master > 0:
            print("Setting up replication...")
            master_idx = 0
            for i in range(master_count, len(node_ips)):
                replica_conn = redis.Redis(host=node_ips[i], port=redis_port, decode_responses=True)
                master_conn = redis.Redis(host=node_ips[master_idx], port=redis_port, decode_responses=True)
                master_id = master_conn.execute_command('CLUSTER', 'MYID')

                print(f"Making {node_ips[i]}:{redis_port} a replica of {node_ips[master_idx]}:{redis_port} (ID: {master_id})")
                replica_conn.execute_command('CLUSTER', 'REPLICATE', master_id)

                master_idx = (master_idx + 1) % master_count

        # Verify cluster
        time.sleep(5)
        cluster_info = coordinator.execute_command('CLUSTER', 'INFO')

        # Convert to string if bytes
        if isinstance(cluster_info, bytes):
            cluster_info_str = cluster_info.decode('utf-8')
        else:
            cluster_info_str = str(cluster_info)

        print(f"Cluster info: {cluster_info_str}")

        if 'cluster_state:ok' not in cluster_info_str:
            raise Exception(f"Cluster state is not OK after initialization. Info: {cluster_info_str}")

        print("Cluster created successfully!")

    except ImportError:
        raise Exception("redis-py library not available. Please package it with Lambda or use manual initialization")
    except Exception as e:
        raise Exception(f"Failed to create cluster: {str(e)}")


def execute_command(cluster_arn: str, task_arn: str, command: str, timeout: int = 30) -> str:
    """
    Execute a command on an ECS task using ECS Exec.

    Note: This requires the ECS service to have enable_execute_command = true
    and the task definition to have the necessary SSM agent running.
    """

    try:
        print(f"Executing command on task {task_arn}: {command}")

        response = ecs_client.execute_command(
            cluster=cluster_arn,
            task=task_arn,
            container='redis',
            interactive=False,
            command=command
        )

        # ECS ExecuteCommand returns a session but doesn't wait for completion
        # The session is handled by SSM in the background
        session_id = response['session']['sessionId']
        print(f"Started ECS Exec session: {session_id}")

        # For cluster initialization, we need to wait for the command to complete
        # Since we can't easily get the output from ECS Exec in Lambda,
        # we'll just wait and then verify the result by checking cluster state
        print(f"Waiting {timeout} seconds for command to complete...")
        time.sleep(timeout)

        print("Command execution completed (timeout reached)")
        return f"Command executed with session {session_id}"

    except Exception as e:
        error_msg = f"Error executing command: {str(e)}"
        print(error_msg)
        # Check if it's a permission error
        if "AccessDeniedException" in str(e):
            print("HINT: Make sure enable_ecs_exec = true on the ECS service")
            print("HINT: Check that the Lambda has ecs:ExecuteCommand permissions")
        raise Exception(error_msg)
