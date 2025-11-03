# Terraform AWS Redis Cluster on ECS Fargate

A Terraform module to deploy a production-ready Redis cluster on AWS ECS Fargate with automatic service discovery using AWS CloudMap.

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
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

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
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

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

- **Port 6379** - Redis client connections (from `allowed_cidr_blocks`)
- **Port 16379** - Redis cluster bus (inter-node communication only)

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

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| cluster_name | Name prefix for Redis cluster resources | string | - | yes |
| vpc_id | VPC ID for deployment | string | - | yes |
| subnet_ids | List of subnet IDs | list(string) | - | yes |
| aws_region | AWS region | string | - | yes |
| redis_master_count | Number of master nodes (min 3) | number | 3 | no |
| redis_replica_count | Number of replica nodes | number | 3 | no |
| redis_image | Redis Docker image | string | redis:7.2-alpine | no |
| task_cpu | CPU units (256, 512, 1024, 2048, 4096) | number | 512 | no |
| task_memory | Memory in MB | number | 1024 | no |
| allowed_cidr_blocks | CIDRs allowed to connect | list(string) | [] | no |
| service_discovery_namespace | CloudMap namespace | string | redis.local | no |
| assign_public_ip | Assign public IP to tasks | bool | false | no |
| enable_container_insights | Enable Container Insights | bool | true | no |
| enable_ecs_exec | Enable ECS Exec | bool | false | no |
| enable_cluster_init | Enable automatic initialization | bool | true | no |
| log_retention_days | CloudWatch log retention | number | 7 | no |
| tags | Tags for all resources | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| ecs_cluster_id | ECS cluster ID |
| ecs_cluster_name | ECS cluster name |
| ecs_service_name | ECS service name |
| security_group_id | Security group ID |
| redis_endpoints | CloudMap DNS endpoint |
| redis_port | Redis port (6379) |
| cloudwatch_log_group_name | Log group name |
| total_nodes | Total number of nodes |
| master_count | Number of masters |
| replica_count | Number of replicas |

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

MIT License - See [LICENSE](LICENSE) file for details.

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

<!-- BEGIN_TF_DOCS -->
# Terraform AWS Redis Cluster on ECS Fargate

A Terraform module to deploy a production-ready Redis cluster on AWS ECS Fargate with automatic service discovery using AWS CloudMap.

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
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

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
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

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

- **Port 6379** - Redis client connections (from `allowed_cidr_blocks`)
- **Port 16379** - Redis cluster bus (inter-node communication only)

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

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| cluster\_name | Name prefix for Redis cluster resources | string | - | yes |
| vpc\_id | VPC ID for deployment | string | - | yes |
| subnet\_ids | List of subnet IDs | list(string) | - | yes |
| aws\_region | AWS region | string | - | yes |
| redis\_master\_count | Number of master nodes (min 3) | number | 3 | no |
| redis\_replica\_count | Number of replica nodes | number | 3 | no |
| redis\_image | Redis Docker image | string | redis:7.2-alpine | no |
| task\_cpu | CPU units (256, 512, 1024, 2048, 4096) | number | 512 | no |
| task\_memory | Memory in MB | number | 1024 | no |
| allowed\_cidr\_blocks | CIDRs allowed to connect | list(string) | [] | no |
| service\_discovery\_namespace | CloudMap namespace | string | redis.local | no |
| assign\_public\_ip | Assign public IP to tasks | bool | false | no |
| enable\_container\_insights | Enable Container Insights | bool | true | no |
| enable\_ecs\_exec | Enable ECS Exec | bool | false | no |
| enable\_cluster\_init | Enable automatic initialization | bool | true | no |
| log\_retention\_days | CloudWatch log retention | number | 7 | no |
| tags | Tags for all resources | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| ecs\_cluster\_id | ECS cluster ID |
| ecs\_cluster\_name | ECS cluster name |
| ecs\_service\_name | ECS service name |
| security\_group\_id | Security group ID |
| redis\_endpoints | CloudMap DNS endpoint |
| redis\_port | Redis port (6379) |
| cloudwatch\_log\_group\_name | Log group name |
| total\_nodes | Total number of nodes |
| master\_count | Number of masters |
| replica\_count | Number of replicas |

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
- Enable Redis maxmemory policies in redis\_environment\_variables
- Monitor with Container Insights

## License

MIT License - See [LICENSE](LICENSE) file for details.

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

<!-- BEGIN\_TF\_DOCS -->
# Terraform AWS Redis Cluster on ECS Fargate

A Terraform module to deploy a production-ready Redis cluster on AWS ECS Fargate with automatic service discovery using AWS CloudMap.

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
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

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
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

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

- **Port 6379** - Redis client connections (from `allowed_cidr_blocks`)
- **Port 16379** - Redis cluster bus (inter-node communication only)

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

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| cluster\\_name | Name prefix for Redis cluster resources | string | - | yes |
| vpc\\_id | VPC ID for deployment | string | - | yes |
| subnet\\_ids | List of subnet IDs | list(string) | - | yes |
| aws\\_region | AWS region | string | - | yes |
| redis\\_master\\_count | Number of master nodes (min 3) | number | 3 | no |
| redis\\_replica\\_count | Number of replica nodes | number | 3 | no |
| redis\\_image | Redis Docker image | string | redis:7.2-alpine | no |
| task\\_cpu | CPU units (256, 512, 1024, 2048, 4096) | number | 512 | no |
| task\\_memory | Memory in MB | number | 1024 | no |
| allowed\\_cidr\\_blocks | CIDRs allowed to connect | list(string) | [] | no |
| service\\_discovery\\_namespace | CloudMap namespace | string | redis.local | no |
| assign\\_public\\_ip | Assign public IP to tasks | bool | false | no |
| enable\\_container\\_insights | Enable Container Insights | bool | true | no |
| enable\\_ecs\\_exec | Enable ECS Exec | bool | false | no |
| enable\\_cluster\\_init | Enable automatic initialization | bool | true | no |
| log\\_retention\\_days | CloudWatch log retention | number | 7 | no |
| tags | Tags for all resources | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| ecs\\_cluster\\_id | ECS cluster ID |
| ecs\\_cluster\\_name | ECS cluster name |
| ecs\\_service\\_name | ECS service name |
| security\\_group\\_id | Security group ID |
| redis\\_endpoints | CloudMap DNS endpoint |
| redis\\_port | Redis port (6379) |
| cloudwatch\\_log\\_group\\_name | Log group name |
| total\\_nodes | Total number of nodes |
| master\\_count | Number of masters |
| replica\\_count | Number of replicas |

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
- Enable Redis maxmemory policies in redis\\_environment\\_variables
- Monitor with Container Insights

## License

MIT License - See [LICENSE](LICENSE) file for details.

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

<!-- BEGIN\\_TF\\_DOCS -->
# Terraform AWS Redis Cluster on ECS Fargate

A Terraform module to deploy a production-ready Redis cluster on AWS ECS Fargate with automatic service discovery using AWS CloudMap.

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
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

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
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

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

- **Port 6379** - Redis client connections (from `allowed_cidr_blocks`)
- **Port 16379** - Redis cluster bus (inter-node communication only)

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

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| cluster\\\_name | Name prefix for Redis cluster resources | string | - | yes |
| vpc\\\_id | VPC ID for deployment | string | - | yes |
| subnet\\\_ids | List of subnet IDs | list(string) | - | yes |
| aws\\\_region | AWS region | string | - | yes |
| redis\\\_master\\\_count | Number of master nodes (min 3) | number | 3 | no |
| redis\\\_replica\\\_count | Number of replica nodes | number | 3 | no |
| redis\\\_image | Redis Docker image | string | redis:7.2-alpine | no |
| task\\\_cpu | CPU units (256, 512, 1024, 2048, 4096) | number | 512 | no |
| task\\\_memory | Memory in MB | number | 1024 | no |
| allowed\\\_cidr\\\_blocks | CIDRs allowed to connect | list(string) | [] | no |
| service\\\_discovery\\\_namespace | CloudMap namespace | string | redis.local | no |
| assign\\\_public\\\_ip | Assign public IP to tasks | bool | false | no |
| enable\\\_container\\\_insights | Enable Container Insights | bool | true | no |
| enable\\\_ecs\\\_exec | Enable ECS Exec | bool | false | no |
| enable\\\_cluster\\\_init | Enable automatic initialization | bool | true | no |
| log\\\_retention\\\_days | CloudWatch log retention | number | 7 | no |
| tags | Tags for all resources | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| ecs\\\_cluster\\\_id | ECS cluster ID |
| ecs\\\_cluster\\\_name | ECS cluster name |
| ecs\\\_service\\\_name | ECS service name |
| security\\\_group\\\_id | Security group ID |
| redis\\\_endpoints | CloudMap DNS endpoint |
| redis\\\_port | Redis port (6379) |
| cloudwatch\\\_log\\\_group\\\_name | Log group name |
| total\\\_nodes | Total number of nodes |
| master\\\_count | Number of masters |
| replica\\\_count | Number of replicas |

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
- Enable Redis maxmemory policies in redis\\\_environment\\\_variables
- Monitor with Container Insights

## License

MIT License - See [LICENSE](LICENSE) file for details.

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

## Requirements

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement\\_terraform"></a> [terraform](#requirement\\\_terraform) | >= 1.0 |
| <a name="requirement\\_archive"></a> [archive](#requirement\\\_archive) | >= 2.0 |
| <a name="requirement\\_aws"></a> [aws](#requirement\\\_aws) | >= 5.0 |

## Providers

## Providers

| Name | Version |
|------|---------|
| <a name="provider\\_archive"></a> [archive](#provider\\\_archive) | >= 2.0 |
| <a name="provider\\_aws"></a> [aws](#provider\\\_aws) | >= 5.0 |

## Resources

## Resources

| Name | Type |
|------|------|
| [aws\\_cloudwatch\\_event\\_rule.ecs\\_service\\_stable](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws\\_cloudwatch\\_event\\_target.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws\\_cloudwatch\\_log\\_group.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws\\_ecs\\_cluster.redis\\_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws\\_ecs\\_service.redis\\_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws\\_ecs\\_task\\_definition.redis\\_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws\\_iam\\_role.ecs\\_task\\_execution\\_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws\\_iam\\_role.ecs\\_task\\_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws\\_iam\\_role.lambda\\_exec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws\\_iam\\_role\\_policy.ecs\\_task\\_cloudmap\\_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role\\_policy) | resource |
| [aws\\_iam\\_role\\_policy.lambda\\_ecs\\_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role\\_policy) | resource |
| [aws\\_iam\\_role\\_policy\\_attachment.ecs\\_task\\_execution\\_role\\_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role\\_policy\\_attachment) | resource |
| [aws\\_iam\\_role\\_policy\\_attachment.lambda\\_vpc\\_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role\\_policy\\_attachment) | resource |
| [aws\\_lambda\\_function.redis\\_cluster\\_init](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws\\_lambda\\_permission.allow\\_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws\\_security\\_group.redis\\_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws\\_service\\_discovery\\_private\\_dns\\_namespace.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_private_dns_namespace) | resource |
| [aws\\_service\\_discovery\\_service.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_service) | resource |

## Inputs

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input\\_cluster\\_name"></a> [cluster\\\_name](#input\\\_cluster\\\_name) | Name prefix for the Redis cluster resources | `string` | n/a | yes |
| <a name="input\\_subnet\\_ids"></a> [subnet\\\_ids](#input\\\_subnet\\\_ids) | List of subnet IDs for Redis tasks (use private subnets) | `list(string)` | n/a | yes |
| <a name="input\\_vpc\\_id"></a> [vpc\\\_id](#input\\\_vpc\\\_id) | VPC ID where Redis cluster will be deployed | `string` | n/a | yes |
| <a name="input\\_allowed\\_cidr\\_blocks"></a> [allowed\\\_cidr\\\_blocks](#input\\\_allowed\\\_cidr\\\_blocks) | CIDR blocks allowed to connect to Redis cluster | `list(string)` | `[]` | no |
| <a name="input\\_assign\\_public\\_ip"></a> [assign\\\_public\\\_ip](#input\\\_assign\\\_public\\\_ip) | Assign public IP to tasks (set to true if using public subnets) | `bool` | `false` | no |
| <a name="input\\_aws\\_region"></a> [aws\\\_region](#input\\\_aws\\\_region) | AWS region for deployment | `string` | `null` | no |
| <a name="input\\_enable\\_cluster\\_init"></a> [enable\\\_cluster\\\_init](#input\\\_enable\\\_cluster\\\_init) | Enable automatic cluster initialization using Lambda | `bool` | `true` | no |
| <a name="input\\_enable\\_container\\_insights"></a> [enable\\\_container\\\_insights](#input\\\_enable\\\_container\\\_insights) | Enable CloudWatch Container Insights for the ECS cluster | `bool` | `true` | no |
| <a name="input\\_enable\\_ecs\\_exec"></a> [enable\\\_ecs\\\_exec](#input\\\_enable\\\_ecs\\\_exec) | Enable ECS Exec for debugging tasks | `bool` | `false` | no |
| <a name="input\\_log\\_retention\\_days"></a> [log\\\_retention\\\_days](#input\\\_log\\\_retention\\\_days) | CloudWatch log retention in days | `number` | `7` | no |
| <a name="input\\_redis\\_environment\\_variables"></a> [redis\\\_environment\\\_variables](#input\\\_redis\\\_environment\\\_variables) | Additional environment variables for Redis containers | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input\\_redis\\_image"></a> [redis\\\_image](#input\\\_redis\\\_image) | Docker image for Redis (must support cluster mode) | `string` | `"redis:7.2-alpine"` | no |
| <a name="input\\_redis\\_master\\_count"></a> [redis\\\_master\\\_count](#input\\\_redis\\\_master\\\_count) | Number of Redis master nodes in the cluster | `number` | `3` | no |
| <a name="input\\_redis\\_replica\\_count"></a> [redis\\\_replica\\\_count](#input\\\_redis\\\_replica\\\_count) | Number of Redis replica nodes (total replicas, not per master) | `number` | `3` | no |
| <a name="input\\_service\\_discovery\\_namespace"></a> [service\\\_discovery\\\_namespace](#input\\\_service\\\_discovery\\\_namespace) | CloudMap namespace for service discovery | `string` | `"redis.local"` | no |
| <a name="input\\_tags"></a> [tags](#input\\\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input\\_task\\_cpu"></a> [task\\\_cpu](#input\\\_task\\\_cpu) | CPU units for Redis task (1024 = 1 vCPU) | `number` | `256` | no |
| <a name="input\\_task\\_memory"></a> [task\\\_memory](#input\\\_task\\\_memory) | Memory for Redis task in MB | `number` | `1024` | no |

## Outputs

## Outputs

| Name | Description |
|------|-------------|
| <a name="output\\_cloudmap\\_namespace\\_id"></a> [cloudmap\\\_namespace\\\_id](#output\\\_cloudmap\\\_namespace\\\_id) | CloudMap namespace ID |
| <a name="output\\_cloudmap\\_namespace\\_name"></a> [cloudmap\\\_namespace\\\_name](#output\\\_cloudmap\\\_namespace\\\_name) | CloudMap namespace name |
| <a name="output\\_cloudmap\\_service\\_id"></a> [cloudmap\\\_service\\\_id](#output\\\_cloudmap\\\_service\\\_id) | CloudMap service ID |
| <a name="output\\_cloudmap\\_service\\_name"></a> [cloudmap\\\_service\\\_name](#output\\\_cloudmap\\\_service\\\_name) | CloudMap service name |
| <a name="output\\_cloudwatch\\_log\\_group\\_name"></a> [cloudwatch\\\_log\\\_group\\\_name](#output\\\_cloudwatch\\\_log\\\_group\\\_name) | CloudWatch log group name |
| <a name="output\\_ecs\\_cluster\\_arn"></a> [ecs\\\_cluster\\\_arn](#output\\\_ecs\\\_cluster\\\_arn) | ECS cluster ARN |
| <a name="output\\_ecs\\_cluster\\_id"></a> [ecs\\\_cluster\\\_id](#output\\\_ecs\\\_cluster\\\_id) | ECS cluster ID |
| <a name="output\\_ecs\\_cluster\\_name"></a> [ecs\\\_cluster\\\_name](#output\\\_ecs\\\_cluster\\\_name) | ECS cluster name |
| <a name="output\\_ecs\\_service\\_id"></a> [ecs\\\_service\\\_id](#output\\\_ecs\\\_service\\\_id) | ECS service ID |
| <a name="output\\_ecs\\_service\\_name"></a> [ecs\\\_service\\\_name](#output\\\_ecs\\\_service\\\_name) | ECS service name |
| <a name="output\\_lambda\\_function\\_name"></a> [lambda\\\_function\\\_name](#output\\\_lambda\\\_function\\\_name) | Lambda function name for cluster initialization |
| <a name="output\\_master\\_count"></a> [master\\\_count](#output\\\_master\\\_count) | Number of master nodes |
| <a name="output\\_redis\\_cluster\\_port"></a> [redis\\\_cluster\\\_port](#output\\\_redis\\\_cluster\\\_port) | Redis cluster bus port |
| <a name="output\\_redis\\_endpoints"></a> [redis\\\_endpoints](#output\\\_redis\\\_endpoints) | Redis cluster endpoints (use CloudMap DNS for discovery) |
| <a name="output\\_redis\\_port"></a> [redis\\\_port](#output\\\_redis\\\_port) | Redis port |
| <a name="output\\_replica\\_count"></a> [replica\\\_count](#output\\\_replica\\\_count) | Number of replica nodes |
| <a name="output\\_security\\_group\\_id"></a> [security\\\_group\\\_id](#output\\\_security\\\_group\\\_id) | Security group ID for Redis cluster |
| <a name="output\\_task\\_definition\\_arn"></a> [task\\\_definition\\\_arn](#output\\\_task\\\_definition\\\_arn) | ECS task definition ARN |
| <a name="output\\_total\\_nodes"></a> [total\\\_nodes](#output\\\_total\\\_nodes) | Total number of Redis nodes (masters + replicas) |
<!-- END\\_TF\\_DOCS -->

## Requirements

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement\_terraform"></a> [terraform](#requirement\\_terraform) | >= 1.0 |
| <a name="requirement\_archive"></a> [archive](#requirement\\_archive) | >= 2.0 |
| <a name="requirement\_aws"></a> [aws](#requirement\\_aws) | >= 5.0 |

## Providers

## Providers

| Name | Version |
|------|---------|
| <a name="provider\_archive"></a> [archive](#provider\\_archive) | >= 2.0 |
| <a name="provider\_aws"></a> [aws](#provider\\_aws) | >= 5.0 |
| <a name="provider\_null"></a> [null](#provider\\_null) | n/a |

## Resources

## Resources

| Name | Type |
|------|------|
| [aws\_cloudwatch\_event\_rule.ecs\_service\_stable](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws\_cloudwatch\_event\_target.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws\_cloudwatch\_log\_group.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws\_ecs\_cluster.redis\_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws\_ecs\_service.redis\_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws\_ecs\_task\_definition.redis\_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws\_iam\_role.ecs\_task\_execution\_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws\_iam\_role.ecs\_task\_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws\_iam\_role.lambda\_exec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws\_iam\_role\_policy.ecs\_task\_cloudmap\_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role\_policy) | resource |
| [aws\_iam\_role\_policy.lambda\_ecs\_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role\_policy) | resource |
| [aws\_iam\_role\_policy\_attachment.ecs\_task\_execution\_role\_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role\_policy\_attachment) | resource |
| [aws\_iam\_role\_policy\_attachment.lambda\_vpc\_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role\_policy\_attachment) | resource |
| [aws\_lambda\_function.redis\_cluster\_init](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws\_lambda\_layer\_version.redis\_layer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws\_lambda\_permission.allow\_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws\_security\_group.redis\_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws\_service\_discovery\_private\_dns\_namespace.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_private_dns_namespace) | resource |
| [aws\_service\_discovery\_service.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_service) | resource |
| [null\_resource.build\_lambda\_layer](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |

## Inputs

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input\_cluster\_name"></a> [cluster\\_name](#input\\_cluster\\_name) | Name prefix for the Redis cluster resources | `string` | n/a | yes |
| <a name="input\_subnet\_ids"></a> [subnet\\_ids](#input\\_subnet\\_ids) | List of subnet IDs for Redis tasks (use private subnets) | `list(string)` | n/a | yes |
| <a name="input\_vpc\_id"></a> [vpc\\_id](#input\\_vpc\\_id) | VPC ID where Redis cluster will be deployed | `string` | n/a | yes |
| <a name="input\_allowed\_cidr\_blocks"></a> [allowed\\_cidr\\_blocks](#input\\_allowed\\_cidr\\_blocks) | CIDR blocks allowed to connect to Redis cluster | `list(string)` | `[]` | no |
| <a name="input\_assign\_public\_ip"></a> [assign\\_public\\_ip](#input\\_assign\\_public\\_ip) | Assign public IP to tasks (set to true if using public subnets) | `bool` | `false` | no |
| <a name="input\_aws\_region"></a> [aws\\_region](#input\\_aws\\_region) | AWS region for deployment | `string` | `null` | no |
| <a name="input\_enable\_cluster\_init"></a> [enable\\_cluster\\_init](#input\\_enable\\_cluster\\_init) | Enable automatic cluster initialization using Lambda via ECS Exec (automatically enables ECS Exec on the service) | `bool` | `true` | no |
| <a name="input\_enable\_container\_insights"></a> [enable\\_container\\_insights](#input\\_enable\\_container\\_insights) | Enable CloudWatch Container Insights for the ECS cluster | `bool` | `true` | no |
| <a name="input\_enable\_ecs\_exec"></a> [enable\\_ecs\\_exec](#input\\_enable\\_ecs\\_exec) | Enable ECS Exec for debugging tasks | `bool` | `false` | no |
| <a name="input\_log\_retention\_days"></a> [log\\_retention\\_days](#input\\_log\\_retention\\_days) | CloudWatch log retention in days | `number` | `7` | no |
| <a name="input\_redis\_environment\_variables"></a> [redis\\_environment\\_variables](#input\\_redis\\_environment\\_variables) | Additional environment variables for Redis containers | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input\_redis\_image"></a> [redis\\_image](#input\\_redis\\_image) | Docker image for Redis (must support cluster mode) | `string` | `"redis:7.2-alpine"` | no |
| <a name="input\_redis\_master\_count"></a> [redis\\_master\\_count](#input\\_redis\\_master\\_count) | Number of Redis master nodes in the cluster | `number` | `3` | no |
| <a name="input\_redis\_replica\_count"></a> [redis\\_replica\\_count](#input\\_redis\\_replica\\_count) | Number of Redis replica nodes (total replicas, not per master) | `number` | `3` | no |
| <a name="input\_service\_discovery\_namespace"></a> [service\\_discovery\\_namespace](#input\\_service\\_discovery\\_namespace) | CloudMap namespace for service discovery | `string` | `"redis.local"` | no |
| <a name="input\_tags"></a> [tags](#input\\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input\_task\_cpu"></a> [task\\_cpu](#input\\_task\\_cpu) | CPU units for Redis task (1024 = 1 vCPU) | `number` | `256` | no |
| <a name="input\_task\_memory"></a> [task\\_memory](#input\\_task\\_memory) | Memory for Redis task in MB | `number` | `1024` | no |

## Outputs

## Outputs

| Name | Description |
|------|-------------|
| <a name="output\_cloudmap\_namespace\_id"></a> [cloudmap\\_namespace\\_id](#output\\_cloudmap\\_namespace\\_id) | CloudMap namespace ID |
| <a name="output\_cloudmap\_namespace\_name"></a> [cloudmap\\_namespace\\_name](#output\\_cloudmap\\_namespace\\_name) | CloudMap namespace name |
| <a name="output\_cloudmap\_service\_id"></a> [cloudmap\\_service\\_id](#output\\_cloudmap\\_service\\_id) | CloudMap service ID |
| <a name="output\_cloudmap\_service\_name"></a> [cloudmap\\_service\\_name](#output\\_cloudmap\\_service\\_name) | CloudMap service name |
| <a name="output\_cloudwatch\_log\_group\_name"></a> [cloudwatch\\_log\\_group\\_name](#output\\_cloudwatch\\_log\\_group\\_name) | CloudWatch log group name |
| <a name="output\_ecs\_cluster\_arn"></a> [ecs\\_cluster\\_arn](#output\\_ecs\\_cluster\\_arn) | ECS cluster ARN |
| <a name="output\_ecs\_cluster\_id"></a> [ecs\\_cluster\\_id](#output\\_ecs\\_cluster\\_id) | ECS cluster ID |
| <a name="output\_ecs\_cluster\_name"></a> [ecs\\_cluster\\_name](#output\\_ecs\\_cluster\\_name) | ECS cluster name |
| <a name="output\_ecs\_service\_id"></a> [ecs\\_service\\_id](#output\\_ecs\\_service\\_id) | ECS service ID |
| <a name="output\_ecs\_service\_name"></a> [ecs\\_service\\_name](#output\\_ecs\\_service\\_name) | ECS service name |
| <a name="output\_lambda\_function\_name"></a> [lambda\\_function\\_name](#output\\_lambda\\_function\\_name) | Lambda function name for cluster initialization |
| <a name="output\_master\_count"></a> [master\\_count](#output\\_master\\_count) | Number of master nodes |
| <a name="output\_redis\_cluster\_port"></a> [redis\\_cluster\\_port](#output\\_redis\\_cluster\\_port) | Redis cluster bus port |
| <a name="output\_redis\_endpoints"></a> [redis\\_endpoints](#output\\_redis\\_endpoints) | Redis cluster endpoints (use CloudMap DNS for discovery) |
| <a name="output\_redis\_port"></a> [redis\\_port](#output\\_redis\\_port) | Redis port |
| <a name="output\_replica\_count"></a> [replica\\_count](#output\\_replica\\_count) | Number of replica nodes |
| <a name="output\_security\_group\_id"></a> [security\\_group\\_id](#output\\_security\\_group\\_id) | Security group ID for Redis cluster |
| <a name="output\_task\_definition\_arn"></a> [task\\_definition\\_arn](#output\\_task\\_definition\\_arn) | ECS task definition ARN |
| <a name="output\_total\_nodes"></a> [total\\_nodes](#output\\_total\\_nodes) | Total number of Redis nodes (masters + replicas) |
<!-- END\_TF\_DOCS -->

## Requirements

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0 |

## Providers

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.0 |
| <a name="provider_null"></a> [null](#provider\_null) | n/a |

## Resources

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_event_rule.ecs_service_stable](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_ecs_cluster.redis_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_service.redis_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.redis_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_role.ecs_task_execution_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ecs_task_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.lambda_exec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.ecs_task_cloudmap_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.lambda_ecs_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.ecs_task_execution_role_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_vpc_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.redis_cluster_init](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_layer_version.redis_layer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws_lambda_permission.allow_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_security_group.redis_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_service_discovery_private_dns_namespace.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_private_dns_namespace) | resource |
| [aws_service_discovery_service.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_service) | resource |
| [null_resource.build_lambda_layer](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |

## Inputs

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name prefix for the Redis cluster resources | `string` | n/a | yes |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | List of subnet IDs for Redis tasks (use private subnets) | `list(string)` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID where Redis cluster will be deployed | `string` | n/a | yes |
| <a name="input_allowed_cidr_blocks"></a> [allowed\_cidr\_blocks](#input\_allowed\_cidr\_blocks) | CIDR blocks allowed to connect to Redis cluster | `list(string)` | `[]` | no |
| <a name="input_assign_public_ip"></a> [assign\_public\_ip](#input\_assign\_public\_ip) | Assign public IP to tasks (set to true if using public subnets) | `bool` | `false` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region for deployment | `string` | `null` | no |
| <a name="input_enable_cluster_init"></a> [enable\_cluster\_init](#input\_enable\_cluster\_init) | Enable automatic cluster initialization using Lambda via ECS Exec (automatically enables ECS Exec on the service) | `bool` | `true` | no |
| <a name="input_enable_container_insights"></a> [enable\_container\_insights](#input\_enable\_container\_insights) | Enable CloudWatch Container Insights for the ECS cluster | `bool` | `true` | no |
| <a name="input_enable_ecs_exec"></a> [enable\_ecs\_exec](#input\_enable\_ecs\_exec) | Enable ECS Exec for debugging tasks | `bool` | `false` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | CloudWatch log retention in days | `number` | `7` | no |
| <a name="input_redis_environment_variables"></a> [redis\_environment\_variables](#input\_redis\_environment\_variables) | Additional environment variables for Redis containers | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_redis_image"></a> [redis\_image](#input\_redis\_image) | Docker image for Redis (must support cluster mode) | `string` | `"redis:7.2-alpine"` | no |
| <a name="input_redis_master_count"></a> [redis\_master\_count](#input\_redis\_master\_count) | Number of Redis master nodes in the cluster | `number` | `3` | no |
| <a name="input_redis_replica_count"></a> [redis\_replica\_count](#input\_redis\_replica\_count) | Number of Redis replica nodes (total replicas, not per master) | `number` | `3` | no |
| <a name="input_service_discovery_namespace"></a> [service\_discovery\_namespace](#input\_service\_discovery\_namespace) | CloudMap namespace for service discovery | `string` | `"redis.local"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_task_cpu"></a> [task\_cpu](#input\_task\_cpu) | CPU units for Redis task (1024 = 1 vCPU) | `number` | `256` | no |
| <a name="input_task_memory"></a> [task\_memory](#input\_task\_memory) | Memory for Redis task in MB | `number` | `1024` | no |

## Outputs

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cloudmap_namespace_id"></a> [cloudmap\_namespace\_id](#output\_cloudmap\_namespace\_id) | CloudMap namespace ID |
| <a name="output_cloudmap_namespace_name"></a> [cloudmap\_namespace\_name](#output\_cloudmap\_namespace\_name) | CloudMap namespace name |
| <a name="output_cloudmap_service_id"></a> [cloudmap\_service\_id](#output\_cloudmap\_service\_id) | CloudMap service ID |
| <a name="output_cloudmap_service_name"></a> [cloudmap\_service\_name](#output\_cloudmap\_service\_name) | CloudMap service name |
| <a name="output_cloudwatch_log_group_name"></a> [cloudwatch\_log\_group\_name](#output\_cloudwatch\_log\_group\_name) | CloudWatch log group name |
| <a name="output_ecs_cluster_arn"></a> [ecs\_cluster\_arn](#output\_ecs\_cluster\_arn) | ECS cluster ARN |
| <a name="output_ecs_cluster_id"></a> [ecs\_cluster\_id](#output\_ecs\_cluster\_id) | ECS cluster ID |
| <a name="output_ecs_cluster_name"></a> [ecs\_cluster\_name](#output\_ecs\_cluster\_name) | ECS cluster name |
| <a name="output_ecs_service_id"></a> [ecs\_service\_id](#output\_ecs\_service\_id) | ECS service ID |
| <a name="output_ecs_service_name"></a> [ecs\_service\_name](#output\_ecs\_service\_name) | ECS service name |
| <a name="output_lambda_function_name"></a> [lambda\_function\_name](#output\_lambda\_function\_name) | Lambda function name for cluster initialization |
| <a name="output_master_count"></a> [master\_count](#output\_master\_count) | Number of master nodes |
| <a name="output_redis_cluster_port"></a> [redis\_cluster\_port](#output\_redis\_cluster\_port) | Redis cluster bus port |
| <a name="output_redis_endpoints"></a> [redis\_endpoints](#output\_redis\_endpoints) | Redis cluster endpoints (use CloudMap DNS for discovery) |
| <a name="output_redis_port"></a> [redis\_port](#output\_redis\_port) | Redis port |
| <a name="output_replica_count"></a> [replica\_count](#output\_replica\_count) | Number of replica nodes |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | Security group ID for Redis cluster |
| <a name="output_task_definition_arn"></a> [task\_definition\_arn](#output\_task\_definition\_arn) | ECS task definition ARN |
| <a name="output_total_nodes"></a> [total\_nodes](#output\_total\_nodes) | Total number of Redis nodes (masters + replicas) |
<!-- END_TF_DOCS -->