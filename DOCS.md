# Redis Cluster on AWS ECS Fargate using Terraform

A Terraform module to deploy a production-ready Redis cluster on AWS ECS Fargate with automatic service discovery using AWS CloudMap.


![AWS ECS Fargate](https://raw.githubusercontent.com/KamranBiglari/terraform-aws-containerize-redis/main/images/aws_ecs_fargate.png)


![AWS ECS Fargate](https://raw.githubusercontent.com/KamranBiglari/terraform-aws-containerize-redis/main/images/redis_insight.png)

## Features

- Redis Cluster Mode on ECS Fargate (serverless)
- Configurable number of master and replica nodes
- AWS CloudMap for service discovery between Redis nodes
- Automatic or manual cluster initialization
- VPC networking with security groups
- CloudWatch logging and optional Container Insights
- Support for ECS Exec for debugging
- Production-ready with health checks

## Architecture

This module creates:

1. **ECS Cluster** - Container orchestration platform
2. **ECS Service** - Manages Redis tasks (one task per Redis node)
3. **ECS Task Definition** - Defines Redis container configuration with cluster mode enabled
4. **CloudMap Namespace & Service** - Private DNS for service discovery between nodes
5. **Security Group** - Controls network access to Redis cluster
6. **Lambda Function** (optional) - Automatically initializes cluster after deployment
7. **CloudWatch Log Group** - Centralized logging for Redis nodes
8. **IAM Roles** - Proper permissions for ECS tasks and Lambda

### How it Works

1. Each Redis node runs as an ECS Fargate task
2. All tasks register with CloudMap for service discovery
3. Redis nodes communicate via CloudMap DNS names
4. After all tasks are running, cluster initialization creates the Redis cluster topology
5. Applications connect via CloudMap DNS: `redis-cluster.redis.local`

## Prerequisites

- AWS Account with appropriate permissions
- Terraform >= 1.0
- VPC with private subnets (recommended)
- Redis CLI tools (for manual initialization)

## Usage

### Basic Example

```hcl
module "redis_cluster" {
  source = "KamranBiglari/containerize-redis/aws"

  cluster_name = "my-redis"
  vpc_id       = "vpc-xxxxx"
  subnet_ids   = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
  aws_region   = "us-east-1"

  # Cluster configuration
  redis_master_count  = 3  # Minimum 3 masters required
  redis_replica_count = 3  # Total replicas (distributed across masters)

  # Network access
  allowed_cidr_blocks = ["10.0.0.0/16"]

  tags = {
    Environment = "production"
  }
}
```

### Complete Example with All Options

```hcl
module "redis_cluster" {
  source = "KamranBiglari/containerize-redis/aws"

  # Basic Configuration
  cluster_name                = "production-redis"
  vpc_id                      = "vpc-xxxxx"
  subnet_ids                  = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
  aws_region                  = "us-east-1"

  # Redis Cluster Configuration
  redis_master_count   = 3   # Number of master nodes (min 3)
  redis_replica_count  = 3   # Number of replicas (1 per master)
  redis_image          = "redis:7.2-alpine"

  # Task Resources
  task_cpu    = 1024  # 1 vCPU
  task_memory = 2048  # 2GB RAM

  # Networking
  assign_public_ip    = false
  allowed_cidr_blocks = ["10.0.0.0/8"]

  # Service Discovery
  service_discovery_namespace = "redis.local"

  # Features
  enable_container_insights = true
  enable_ecs_exec          = true   # For debugging
  enable_cluster_init      = true   # Auto-initialize cluster
  log_retention_days       = 30

  # Environment Variables (optional)
  # Note: REDIS_PORT and REDIS_CLUSTER_PORT are automatically set
  redis_environment_variables = [
    {
      name  = "TZ"
      value = "UTC"
    }
  ]

  tags = {
    Environment = "production"
    Project     = "my-app"
    ManagedBy   = "terraform"
  }
}
```

## Cluster Configuration

### Master and Replica Nodes

Redis Cluster requires at least **3 master nodes** for high availability and proper hash slot distribution.

**Recommended Configurations:**

| Masters | Replicas | Total Nodes | Replicas per Master | Use Case |
|---------|----------|-------------|---------------------|----------|
| 3       | 3        | 6           | 1                   | Production (recommended) |
| 3       | 0        | 3           | 0                   | Development/Testing |
| 3       | 6        | 9           | 2                   | High Availability |
| 5       | 5        | 10          | 1                   | Large Production |

### How Replicas are Distributed

The module automatically distributes replicas across master nodes:

- `replicas_per_master = redis_replica_count / redis_master_count`
- With 3 masters and 3 replicas: each master gets 1 replica
- With 3 masters and 6 replicas: each master gets 2 replicas

## Service Discovery

All Redis nodes are registered in AWS CloudMap and can communicate with each other using the service DNS name:

```
redis-cluster.redis.local
```

Your applications should connect using this DNS name. Redis clients will automatically discover all cluster nodes.

**Connection Example (Python):**

```python
from redis.cluster import RedisCluster

cluster = RedisCluster(
    host='redis-cluster.redis.local',
    port=6379,
    decode_responses=True
)

cluster.set('key', 'value')
print(cluster.get('key'))
```

## Cluster Initialization

### Automatic Initialization (Recommended)

Set `enable_cluster_init = true` to use the Lambda-based automatic initialization:

- Lambda waits for all ECS tasks to be running
- Discovers node IPs via ECS API
- Runs `redis-cli --cluster create` command
- Verifies cluster is healthy

### Manual Initialization

If you prefer manual control or automatic initialization fails:

1. Wait for all ECS tasks to be running:

```bash
aws ecs describe-services \
  --cluster <cluster-name>-redis \
  --services <cluster-name>-redis-service \
  --region <region>
```

2. Run the initialization script:

```bash
export ECS_CLUSTER="<cluster-name>-redis"
export ECS_SERVICE="<cluster-name>-redis-service"
export MASTER_COUNT=3
export REPLICA_COUNT=3
export AWS_REGION="us-east-1"

./scripts/init-cluster.sh
```

3. Or manually using redis-cli from within VPC:

```bash
# Get node IPs from ECS console or CLI
redis-cli --cluster create \
  10.0.1.10:6379 10.0.1.11:6379 10.0.1.12:6379 \
  10.0.1.13:6379 10.0.1.14:6379 10.0.1.15:6379 \
  --cluster-replicas 1 \
  --cluster-yes
```

## Networking

### Security Groups

The module creates a security group with:

- **Port 6379** (`redis_port`) - Redis client connections (from `allowed_cidr_blocks`)
- **Port 16379** (`redis_cluster_port`, default `redis_port` + 10000) - Redis cluster bus (inter-node communication only)

### Subnet Selection

**Best Practice:** Use private subnets for Redis cluster

- Set `assign_public_ip = false`
- Deploy in private subnets with NAT Gateway for outbound access
- Use VPC endpoints if needed

### Accessing Redis from Applications

Applications must be in the same VPC or have VPC peering/Transit Gateway configured.

## Monitoring

### CloudWatch Logs

All Redis logs are sent to CloudWatch Logs:

```
/ecs/<cluster-name>-redis
```

View logs:

```bash
aws logs tail /ecs/<cluster-name>-redis --follow
```

### Container Insights

Enable with `enable_container_insights = true` for metrics:

- CPU and Memory utilization
- Network traffic
- Task-level metrics

### Health Checks

Each task has a health check:

```bash
redis-cli ping | grep PONG
```

## Debugging

### Enable ECS Exec

Set `enable_ecs_exec = true` to connect to running containers:

```bash
# List tasks
aws ecs list-tasks --cluster <cluster-name>-redis --service <cluster-name>-redis-service

# Connect to a task
aws ecs execute-command \
  --cluster <cluster-name>-redis \
  --task <task-id> \
  --container redis \
  --interactive \
  --command "/bin/sh"
```

Inside container:

```bash
# Check cluster status
redis-cli cluster info
redis-cli cluster nodes

# Check node health
redis-cli ping

# Get cluster configuration
redis-cli cluster slots
```

## Scaling

To scale the cluster:

1. Update `redis_master_count` or `redis_replica_count`
2. Run `terraform apply`
3. Re-initialize cluster with new topology (requires manual resharding)

**Note:** Redis Cluster resharding must be done carefully to avoid data loss. The module handles adding nodes, but you must manually rebalance hash slots.

## Cost Optimization

### Fargate Pricing Factors

- **vCPU hours** - Based on `task_cpu`
- **Memory GB-hours** - Based on `task_memory`
- **Number of tasks** - `redis_master_count + redis_replica_count`

### Cost Estimates (us-east-1)

| Configuration | vCPU | Memory | Nodes | Monthly Cost (approx) |
|---------------|------|--------|-------|----------------------|
| Dev (minimal) | 0.25 | 512MB  | 3     | ~$15-20              |
| Prod (small)  | 0.5  | 1GB    | 6     | ~$60-80              |
| Prod (medium) | 1    | 2GB    | 6     | ~$120-150            |

Use AWS Pricing Calculator for exact estimates.


## Troubleshooting

### Tasks Not Starting

1. Check ECS service events:

```bash
aws ecs describe-services \
  --cluster <cluster-name>-redis \
  --services <cluster-name>-redis-service
```

2. Check CloudWatch logs for errors
3. Verify subnet has NAT Gateway (if `assign_public_ip = false`)
4. Check security group rules

### Cluster Initialization Fails

1. Verify all tasks are running and healthy
2. Check Lambda logs (if using auto-init):

```bash
aws logs tail /aws/lambda/<cluster-name>-redis-cluster-init --follow
```

3. Try manual initialization using the script
4. Verify nodes can communicate (ports 6379 and 16379 open between nodes)

### Connection Timeouts

1. Verify security group allows traffic from your application
2. Check application is in same VPC or has network connectivity
3. Verify CloudMap DNS resolution works:

```bash
dig redis-cluster.redis.local
```

### High Memory Usage

- Increase `task_memory`
- Enable Redis maxmemory policies in redis_environment_variables
- Monitor with Container Insights

## License

 See [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## Support

For issues and questions:

- Open a GitHub issue
- Check AWS ECS and Redis documentation

## References

- [Redis Cluster Tutorial](https://redis.io/docs/management/scaling/)
- [AWS ECS Fargate](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html)
- [AWS CloudMap](https://docs.aws.amazon.com/cloud-map/latest/dg/what-is-cloud-map.html)
- [Redis on AWS](https://aws.amazon.com/redis/)



