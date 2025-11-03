# Quick Start Guide

Get your Redis cluster running in 10 minutes!

## Prerequisites

- AWS Account with CLI configured
- Terraform installed
- VPC with private subnets
- Redis CLI tools installed (for verification)

## Step 1: Create Terraform Configuration

Create a new directory and add `main.tf`:

```hcl
module "redis_cluster" {
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

  cluster_name = "my-redis"
  vpc_id       = "vpc-xxxxx"        # Replace with your VPC ID
  subnet_ids   = [                   # Replace with your subnet IDs
    "subnet-xxxxx",
    "subnet-yyyyy",
    "subnet-zzzzz"
  ]
  aws_region   = "us-east-1"        # Replace with your region

  # Minimal cluster: 3 masters, 3 replicas
  redis_master_count  = 3
  redis_replica_count = 3

  # Allow access from your VPC
  allowed_cidr_blocks = ["10.0.0.0/16"]  # Replace with your VPC CIDR

  tags = {
    Environment = "dev"
  }
}

output "redis_endpoint" {
  value = module.redis_cluster.redis_endpoints
}

output "cluster_name" {
  value = module.redis_cluster.ecs_cluster_name
}
```

## Step 2: Deploy

```bash
terraform init
terraform plan
terraform apply
```

This will create:
- 1 ECS Cluster
- 1 ECS Service with 6 tasks (3 masters + 3 replicas)
- CloudMap namespace for service discovery
- Security groups and IAM roles
- Lambda function for cluster initialization

**Deployment time: ~5-7 minutes**

## Step 3: Wait for Initialization

The Lambda function will automatically initialize the cluster once all tasks are running.

Monitor the logs:

```bash
aws logs tail /aws/lambda/my-redis-redis-cluster-init --follow
```

Or check the ECS service:

```bash
aws ecs describe-services \
  --cluster my-redis-redis \
  --services my-redis-redis-service
```

## Step 4: Verify Cluster

Once all tasks are healthy, verify the cluster:

```bash
# Set environment variables
export ECS_CLUSTER="my-redis-redis"
export ECS_SERVICE="my-redis-redis-service"
export AWS_REGION="us-east-1"

# Run health check
./scripts/check-cluster.sh
```

You should see output like:

```
Tasks: 6 / 6

Redis Nodes:
  - 10.0.1.10
  - 10.0.1.11
  - 10.0.1.12
  - 10.0.1.13
  - 10.0.1.14
  - 10.0.1.15

Cluster Info:
cluster_state:ok
cluster_slots_assigned:16384
cluster_slots_ok:16384
cluster_slots_pfail:0
cluster_slots_fail:0
cluster_known_nodes:6
...
```

## Step 5: Connect Your Application

Your application should connect using the CloudMap DNS endpoint:

**Endpoint:** `redis-cluster.redis.local`

### Python Example

```python
from redis.cluster import RedisCluster

cluster = RedisCluster(
    host='redis-cluster.redis.local',
    port=6379,
    decode_responses=True
)

# Test connection
cluster.set('test_key', 'Hello Redis!')
print(cluster.get('test_key'))  # Output: Hello Redis!
```

### Node.js Example

```javascript
const Redis = require('ioredis');

const cluster = new Redis.Cluster([
  { host: 'redis-cluster.redis.local', port: 6379 }
]);

cluster.set('test_key', 'Hello Redis!');
cluster.get('test_key', (err, result) => {
  console.log(result);  // Output: Hello Redis!
});
```

### Go Example

```go
package main

import (
    "github.com/go-redis/redis/v8"
    "context"
)

func main() {
    ctx := context.Background()

    client := redis.NewClusterClient(&redis.ClusterOptions{
        Addrs: []string{"redis-cluster.redis.local:6379"},
    })

    err := client.Set(ctx, "test_key", "Hello Redis!", 0).Err()
    if err != nil {
        panic(err)
    }

    val, err := client.Get(ctx, "test_key").Result()
    if err != nil {
        panic(err)
    }
    println(val)  // Output: Hello Redis!
}
```

## Common Issues

### Cluster Initialization Fails

**Manual initialization:**

```bash
export ECS_CLUSTER="my-redis-redis"
export ECS_SERVICE="my-redis-redis-service"
export MASTER_COUNT=3
export REPLICA_COUNT=3
export AWS_REGION="us-east-1"

./scripts/init-cluster.sh
```

### Can't Connect from Application

1. **Verify DNS resolution** - Your app must be in the same VPC
2. **Check security groups** - Add your app's security group to `allowed_cidr_blocks`
3. **Test connection:**

```bash
# From within VPC (e.g., EC2 instance or ECS task)
redis-cli -h redis-cluster.redis.local ping
# Should return: PONG
```

### Tasks Not Starting

1. **Check subnet has NAT Gateway** (if using private subnets)
2. **Verify IAM permissions**
3. **Check CloudWatch logs:**

```bash
aws logs tail /ecs/my-redis-redis --follow
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

This will remove:
- All ECS tasks and services
- Security groups
- CloudMap namespace
- Lambda function
- CloudWatch logs (based on retention period)

## Next Steps

- [Read the full README](README.md) for advanced configuration
- Configure monitoring and alerting
- Set up backups (add EFS persistence)
- Tune Redis configuration
- Set up application load testing

## Cost Estimate

For the minimal configuration (3 masters + 3 replicas with 0.5 vCPU and 1GB RAM each):

**~$60-80/month** in us-east-1

Use [AWS Pricing Calculator](https://calculator.aws.amazon.com/) for precise estimates.

## Support

For issues:
- Check [README.md](README.md) troubleshooting section
- Open a GitHub issue
- Review CloudWatch logs
