<!-- BEGIN_TF_DOCS -->
# Redis Cluster on AWS ECS Fargate using Terraform

[![Terraform Registry](https://img.shields.io/badge/Terraform%20Registry-KamranBiglari%2Fcontainerize--redis-blue)](https://registry.terraform.io/modules/KamranBiglari/containerize-redis/aws/latest)
[![GitHub](https://img.shields.io/badge/GitHub-KamranBiglari%2Fterraform--aws--containerize--redis-black)](https://github.com/KamranBiglari/terraform-aws-containerize-redis)
![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.0-purple)
![AWS](https://img.shields.io/badge/AWS-IAM%20%7C%20S3%20%7C%20CloudFront-orange)

A Terraform module to deploy a production-ready Redis cluster on AWS ECS Fargate with automatic service discovery using AWS CloudMap.

![Redis Cluster on AWS ECS Fargate](https://raw.githubusercontent.com/KamranBiglari/terraform-aws-containerize-redis/main/images/social-preview_1.png)

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
- Terraform >= 1.3
- VPC with private subnets (recommended)
- `bash` on the machine running Terraform, plus Docker (recommended) or Python 3
  with pip, to build the initialization Lambda layer - see
  [Building the Lambda layer](#building-the-lambda-layer). Not needed with
  `enable_cluster_init = false`.
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

  # Network access. With cluster initialization enabled (the default) these rules
  # are applied by the init Lambda once the cluster is healthy, not during apply.
  allowed_cidr_blocks = ["10.0.0.0/16"]

  tags = {
    Environment = "production"
  }
}
```

This creates its own ECS cluster, CloudWatch log group and CloudMap namespace, and
runs Redis without a password. Each of those is optional - see
[Using existing infrastructure](#using-existing-infrastructure) and
[Authentication](#authentication).

### Complete Example with All Options

```hcl
module "redis_cluster" {
  source = "KamranBiglari/containerize-redis/aws"

  # Basic Configuration
  cluster_name = "production-redis"
  vpc_id       = "vpc-xxxxx"
  subnet_ids   = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
  aws_region   = "us-east-1"

  # Redis Cluster Configuration
  redis_master_count  = 3 # Number of master nodes (min 3)
  redis_replica_count = 3 # Number of replicas (1 per master)
  redis_image         = "redis:7.2-alpine"

  # Ports. redis_cluster_port defaults to redis_port + 10000, the offset Redis
  # itself uses, so set it only to pin a specific bus port.
  redis_port = 6379

  # Task Resources
  task_cpu    = 1024 # 1 vCPU
  task_memory = 2048 # 2GB RAM

  # Networking
  assign_public_ip    = false
  allowed_cidr_blocks = ["10.0.0.0/8"]

  # ECS cluster: created here, or reuse one you already run
  create_ecs_cluster = true
  ecs_cluster_name   = "production-redis-cluster"
  # create_ecs_cluster        = false
  # existing_ecs_cluster_name = "shared-infrastructure"

  # CloudWatch logs
  create_cloudwatch_log_group = true
  log_retention_days          = 30
  # create_cloudwatch_log_group        = false
  # existing_cloudwatch_log_group_name = "/ecs/shared"

  # Service discovery
  create_service_discovery_namespace = true
  service_discovery_namespace        = "redis.local"
  service_discovery_name             = "redis-cluster"
  # create_service_discovery_namespace        = false
  # existing_service_discovery_namespace_name = "services.internal"
  # existing_service_discovery_namespace_type = "DNS_PRIVATE"

  # Authentication. Omit all of these to run without a password.
  create_redis_password_secret = true
  redis_password               = var.redis_password # generated when not supplied
  # existing_redis_password_secret_arn = aws_secretsmanager_secret.redis.arn
  # existing_redis_password_secret_key = "password"

  # Cluster initialization
  enable_cluster_init       = true # Auto-initialize on every deployment
  cluster_init_timeout      = 900
  lambda_layer_build_method = "auto" # auto | docker | python

  # Extra time on destroy for CloudMap instances to deregister
  service_discovery_deregistration_delay = "120s"

  # Features
  enable_container_insights = true
  enable_ecs_exec           = true # For debugging

  # Environment Variables (optional)
  # Note: REDIS_PORT and REDIS_CLUSTER_PORT are set by the module
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

A runnable version of this lives in [examples/complete](examples/complete).

### Using existing infrastructure

Everything the module creates alongside the Redis service can be swapped for
something you already have. Each follows the same three-variable shape: a
`create_*` toggle, a name used when creating, and an `existing_*` value used when
reusing.

| Resource | Create | Reuse |
|----------|--------|-------|
| ECS cluster | `create_ecs_cluster`, `ecs_cluster_name` | `existing_ecs_cluster_name` |
| CloudWatch log group | `create_cloudwatch_log_group`, `cloudwatch_log_group_name` | `existing_cloudwatch_log_group_name` |
| CloudMap namespace | `create_service_discovery_namespace`, `service_discovery_namespace` | `existing_service_discovery_namespace_name`, `existing_service_discovery_namespace_type` |
| Password secret | `create_redis_password_secret`, `redis_password`, `redis_password_secret_name` | `existing_redis_password_secret_arn`, `existing_redis_password_secret_key` |

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

The Lambda runs on **every** deployment, not just the first: a restart or a new
task definition replaces every Redis node, and the replacements come back empty
with new IPs. It is a no-op when it finds a healthy cluster already in place.

### Building the Lambda layer

The Lambda needs a layer containing `redis-py`. It is built locally during
`terraform apply` by `lambda/build_layer.sh`, and rebuilt whenever it is missing -
the built layer is not part of the module source, so a freshly downloaded module
directory has none.

By default (`lambda_layer_build_method = "auto"`) the build runs in a container and
needs nothing on the machine except `bash` and Docker. Without Docker it falls back
to the host's `python3`/`pip`, which is convenient locally but depends on what the
machine has installed - and off Linux/x86\_64 it can produce wheels the Lambda
runtime cannot load. Set the method to `docker` to fail loudly instead of falling
back, or to `python` to skip Docker entirely. `lambda_layer_build_image` selects the
build image.

CI runners generally have Docker (`ubuntu-latest` does), so `auto` resolves to the
container build there.

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

#### Client access is gated on cluster initialization

Redis will not form a cluster out of nodes that already contain keys, so a client
that connects and writes before initialization leaves the cluster unformable.

With `enable_cluster_init = true` the `allowed_cidr_blocks` rules are therefore
managed by the initialization Lambda rather than by Terraform. On every deployment
it:

1. revokes the client rules (matched by description) unless the nodes are already a
   healthy cluster,
2. waits for the ECS service to stabilize,
3. verifies every node is empty - no keys, no cluster state - and refuses to
   continue otherwise,
4. forms the cluster, and
5. re-authorizes the client rules.

If initialization fails the rules stay revoked, and the next steady-state event
retries. With `enable_cluster_init = false` Terraform manages the rules directly.

There is a small window on a restart: replaced tasks accept connections from the
moment they start until the Lambda revokes access. Keep `allowed_cidr_blocks` as
tight as possible.

### Authentication

Redis runs without a password by default. Turning on AUTH means having a secret,
and the module can either create one or use one you already have.

Let the module create it - the password is generated unless you pass one:

```hcl
create_redis_password_secret = true
redis_password               = var.redis_password # optional
```

Or point it at a secret you manage:

```hcl
existing_redis_password_secret_arn = aws_secretsmanager_secret.redis.arn
existing_redis_password_secret_key = "password" # omit if the secret is the raw password
```

Either way the ARN comes back as the `redis_password_secret_arn` output. A secret
created by the module holds a connection document rather than a bare password, so
an application can get everything it needs from one place:

```json
{
  "host": "redis-cluster.redis.local",
  "password": "...",
  "port": 6379,
  "type": "redis-cluster"
}
```

The password is never rendered into the task definition: ECS injects it as the
`REDIS_PASSWORD` container secret, and nodes start with `--requirepass` and
`--masterauth` (replicas need the latter to authenticate to their master). The
health check and the initialization Lambda authenticate with the same secret.

Clients then need the password: `redis-cli -c -h <endpoint> -a <password>`.

Note that the password is stored in Terraform state whether you supply it or let
the module generate it, so treat state as sensitive.

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

### Apply fails: "Creation of service was not idempotent"

```
InvalidParameterException: Creation of service was not idempotent.
```

ECS reserves a deleted service's name while its tasks drain, and rejects
`CreateService` with that name until the drain finishes. It appears when the
service is replaced under an unchanged name, since Terraform destroys and recreates
it in a single pass. Re-running the apply succeeds once the old tasks are gone.

The durable fix is to stop the replacement. Only `name`, `cluster`, `launch_type`,
`service_registries` and `deployment_controller` force one. Find the culprit with:

```bash
terraform plan | grep -A5 "aws_ecs_service.redis_cluster must be replaced"
```

If `cluster` shows `(known after apply)`, the cluster name reaching the module is
not known at plan time - pass a literal name rather than a computed value. If
`service_registries` is responsible, something is replacing the CloudMap service.

In CI, retrying once is a reasonable guard:

```yaml
- name: Terraform apply
  run: terraform apply -auto-approve || (sleep 120 && terraform apply -auto-approve)
```

### Destroy fails: "Service contains registered instances"

```
ResourceInUse: Service contains registered instances; delete the instances before deleting the service
```

The same race on the way down: ECS deregisters CloudMap instances asynchronously
after the service is deleted. The module waits between the two steps - raise
`service_discovery_deregistration_delay` if the default is not enough - and
re-running the destroy always clears it.

### High Memory Usage

- Increase `task_memory`
- Enable Redis maxmemory policies in redis\_environment\_variables
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

## Requirements

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.9 |

## Providers

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.0 |
| <a name="provider_null"></a> [null](#provider\_null) | n/a |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.9 |

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
| [aws_iam_role_policy.ecs_task_execution_secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.lambda_ecs_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.ecs_task_execution_role_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_vpc_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.redis_cluster_init](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_layer_version.redis_layer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws_lambda_permission.allow_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_secretsmanager_secret.redis_password](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.redis_password](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.redis_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_service_discovery_private_dns_namespace.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_private_dns_namespace) | resource |
| [aws_service_discovery_service.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_service) | resource |
| [aws_vpc_security_group_egress_rule.redis_all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.redis_bus](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.redis_client](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.redis_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [null_resource.build_lambda_layer](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [random_password.redis](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_sleep.service_discovery_deregistration](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |

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
| <a name="input_cloudwatch_log_group_name"></a> [cloudwatch\_log\_group\_name](#input\_cloudwatch\_log\_group\_name) | Name of the CloudWatch log group to create. Only used when `create_cloudwatch_log_group` is true. Defaults to `"/ecs/<cluster_name>-redis"`. | `string` | `null` | no |
| <a name="input_cluster_init_timeout"></a> [cluster\_init\_timeout](#input\_cluster\_init\_timeout) | Timeout in seconds for the cluster initialization Lambda. It has to cover waiting for the ECS service to stabilize plus forming the cluster. | `number` | `900` | no |
| <a name="input_create_cloudwatch_log_group"></a> [create\_cloudwatch\_log\_group](#input\_create\_cloudwatch\_log\_group) | Whether to create a CloudWatch log group for the Redis tasks. Set to false to log into an existing group provided via `existing_cloudwatch_log_group_name`. | `bool` | `true` | no |
| <a name="input_create_ecs_cluster"></a> [create\_ecs\_cluster](#input\_create\_ecs\_cluster) | Whether to create a new ECS cluster for the Redis service. Set to false to deploy into an existing cluster provided via `existing_ecs_cluster_name`. | `bool` | `true` | no |
| <a name="input_create_redis_password_secret"></a> [create\_redis\_password\_secret](#input\_create\_redis\_password\_secret) | Whether to create a Secrets Manager secret holding the Redis password. Setting this, or `existing_redis_password_secret_arn`, turns on Redis AUTH; with neither the cluster runs unauthenticated. | `bool` | `false` | no |
| <a name="input_create_service_discovery_namespace"></a> [create\_service\_discovery\_namespace](#input\_create\_service\_discovery\_namespace) | Whether to create a CloudMap private DNS namespace. Set to false to register the Redis service in an existing namespace provided via `existing_service_discovery_namespace_name`. | `bool` | `true` | no |
| <a name="input_ecs_cluster_name"></a> [ecs\_cluster\_name](#input\_ecs\_cluster\_name) | Name of the ECS cluster to create. Only used when `create_ecs_cluster` is true. Defaults to `"<cluster_name>-redis"`. | `string` | `null` | no |
| <a name="input_ecs_service_config_tags"></a> [ecs\_service\_config\_tags](#input\_ecs\_service\_config\_tags) | Tags to apply to aws ecs service | `map(string)` | <pre>{<br/>  "desired_count": "Config:desiredCount"<br/>}</pre> | no |
| <a name="input_enable_cluster_init"></a> [enable\_cluster\_init](#input\_enable\_cluster\_init) | Enable automatic cluster initialization using Lambda via ECS Exec (automatically enables ECS Exec on the service) | `bool` | `true` | no |
| <a name="input_enable_container_insights"></a> [enable\_container\_insights](#input\_enable\_container\_insights) | Enable CloudWatch Container Insights for the ECS cluster | `bool` | `true` | no |
| <a name="input_enable_ecs_exec"></a> [enable\_ecs\_exec](#input\_enable\_ecs\_exec) | Enable ECS Exec for debugging tasks | `bool` | `false` | no |
| <a name="input_existing_cloudwatch_log_group_name"></a> [existing\_cloudwatch\_log\_group\_name](#input\_existing\_cloudwatch\_log\_group\_name) | Name of an existing CloudWatch log group to send Redis task logs to. Required when `create_cloudwatch_log_group` is false, ignored otherwise. | `string` | `null` | no |
| <a name="input_existing_ecs_cluster_name"></a> [existing\_ecs\_cluster\_name](#input\_existing\_ecs\_cluster\_name) | Name of an existing ECS cluster to deploy the Redis service into. Required when `create_ecs_cluster` is false, ignored otherwise. | `string` | `null` | no |
| <a name="input_existing_redis_password_secret_arn"></a> [existing\_redis\_password\_secret\_arn](#input\_existing\_redis\_password\_secret\_arn) | ARN of an existing Secrets Manager secret holding the Redis password. Use instead of `create_redis_password_secret` to bring your own secret. | `string` | `null` | no |
| <a name="input_existing_redis_password_secret_key"></a> [existing\_redis\_password\_secret\_key](#input\_existing\_redis\_password\_secret\_key) | Key to read from an existing JSON-encoded secret, for example `password`. Leave null when the secret's value is the password itself. Only used with `existing_redis_password_secret_arn`. | `string` | `null` | no |
| <a name="input_existing_service_discovery_namespace_name"></a> [existing\_service\_discovery\_namespace\_name](#input\_existing\_service\_discovery\_namespace\_name) | Name of an existing CloudMap private DNS namespace to register the Redis service in. Required when `create_service_discovery_namespace` is false, ignored otherwise. The namespace must already exist when this module is planned. | `string` | `null` | no |
| <a name="input_existing_service_discovery_namespace_type"></a> [existing\_service\_discovery\_namespace\_type](#input\_existing\_service\_discovery\_namespace\_type) | Type of the existing CloudMap namespace to look up: `DNS_PRIVATE` or `DNS_PUBLIC`. Only used when `create_service_discovery_namespace` is false. | `string` | `"DNS_PRIVATE"` | no |
| <a name="input_lambda_layer_build_image"></a> [lambda\_layer\_build\_image](#input\_lambda\_layer\_build\_image) | Container image used to build the Lambda layer when the build method resolves to Docker. | `string` | `"public.ecr.aws/sam/build-python3.11"` | no |
| <a name="input_lambda_layer_build_interpreter"></a> [lambda\_layer\_build\_interpreter](#input\_lambda\_layer\_build\_interpreter) | Interpreter used to run `lambda/build_layer.sh`, which builds the Lambda layer. The default needs `bash` on PATH - on Windows, Git Bash satisfies this. | `list(string)` | <pre>[<br/>  "bash",<br/>  "-c"<br/>]</pre> | no |
| <a name="input_lambda_layer_build_method"></a> [lambda\_layer\_build\_method](#input\_lambda\_layer\_build\_method) | How to build the Lambda layer: `docker` builds it in a container matching the Lambda runtime, `python` uses the host's pip, and `auto` prefers Docker and falls back to pip. Docker needs nothing installed beyond Docker itself and is the only option that guarantees Linux/x86\_64 wheels. | `string` | `"auto"` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | CloudWatch log retention in days | `number` | `7` | no |
| <a name="input_redis_cluster_port"></a> [redis\_cluster\_port](#input\_redis\_cluster\_port) | Port for the Redis Cluster bus. Defaults to `redis_port` + 10000, which is the offset Redis itself uses when `cluster-port` is unset. | `number` | `null` | no |
| <a name="input_redis_environment_variables"></a> [redis\_environment\_variables](#input\_redis\_environment\_variables) | Additional environment variables for Redis containers | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_redis_image"></a> [redis\_image](#input\_redis\_image) | Docker image for Redis (must support cluster mode) | `string` | `"redis:7.2-alpine"` | no |
| <a name="input_redis_master_count"></a> [redis\_master\_count](#input\_redis\_master\_count) | Number of Redis master nodes in the cluster | `number` | `3` | no |
| <a name="input_redis_password"></a> [redis\_password](#input\_redis\_password) | Password to store in the created secret. Only used when `create_redis_password_secret` is true; when left null a strong password is generated. | `string` | `null` | no |
| <a name="input_redis_password_secret_name"></a> [redis\_password\_secret\_name](#input\_redis\_password\_secret\_name) | Name of the Secrets Manager secret to create. Only used when `create_redis_password_secret` is true. Defaults to `"<cluster_name>-redis-password"`. | `string` | `null` | no |
| <a name="input_redis_port"></a> [redis\_port](#input\_redis\_port) | Port for Redis | `number` | `6379` | no |
| <a name="input_redis_replica_count"></a> [redis\_replica\_count](#input\_redis\_replica\_count) | Number of Redis replica nodes (total replicas, not per master) | `number` | `3` | no |
| <a name="input_service_discovery_deregistration_delay"></a> [service\_discovery\_deregistration\_delay](#input\_service\_discovery\_deregistration\_delay) | How long to wait, on destroy, between deleting the ECS service and deleting the CloudMap service, so that task instances finish deregistering. Raise it if destroys fail with `ResourceInUse: Service contains registered instances`. | `string` | `"120s"` | no |
| <a name="input_service_discovery_name"></a> [service\_discovery\_name](#input\_service\_discovery\_name) | CloudMap service name for Redis | `string` | `"redis-cluster"` | no |
| <a name="input_service_discovery_namespace"></a> [service\_discovery\_namespace](#input\_service\_discovery\_namespace) | Name of the CloudMap private DNS namespace to create. Only used when `create_service_discovery_namespace` is true. | `string` | `"redis.local"` | no |
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
| <a name="output_elasticache_compatible"></a> [elasticache\_compatible](#output\_elasticache\_compatible) | Whether the configuration is compatible with ElastiCache |
| <a name="output_lambda_function_name"></a> [lambda\_function\_name](#output\_lambda\_function\_name) | Lambda function name for cluster initialization |
| <a name="output_master_count"></a> [master\_count](#output\_master\_count) | Number of master nodes |
| <a name="output_redis_cluster_port"></a> [redis\_cluster\_port](#output\_redis\_cluster\_port) | Redis cluster bus port |
| <a name="output_redis_endpoints"></a> [redis\_endpoints](#output\_redis\_endpoints) | Redis cluster endpoints (use CloudMap DNS for discovery) |
| <a name="output_redis_password_secret_arn"></a> [redis\_password\_secret\_arn](#output\_redis\_password\_secret\_arn) | ARN of the Secrets Manager secret holding the Redis password, or null when the cluster is unauthenticated |
| <a name="output_redis_password_secret_id"></a> [redis\_password\_secret\_id](#output\_redis\_password\_secret\_id) | ID of the Secrets Manager secret holding the Redis password, for passing to `secret_id` arguments, or null when the cluster is unauthenticated. Secrets Manager identifies secrets by ARN, so this matches redis\_password\_secret\_arn. |
| <a name="output_redis_port"></a> [redis\_port](#output\_redis\_port) | Redis port |
| <a name="output_replica_count"></a> [replica\_count](#output\_replica\_count) | Number of replica nodes |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | Security group ID for Redis cluster |
| <a name="output_task_definition_arn"></a> [task\_definition\_arn](#output\_task\_definition\_arn) | ECS task definition ARN |
| <a name="output_total_nodes"></a> [total\_nodes](#output\_total\_nodes) | Total number of Redis nodes (masters + replicas) |
<!-- END_TF_DOCS -->