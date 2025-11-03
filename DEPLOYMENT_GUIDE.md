# Deployment Guide - Redis Cluster on ECS Fargate

Complete step-by-step guide to deploy your Redis cluster with automatic Lambda-based initialization.

## Overview

This module uses a Lambda function that connects directly to Redis nodes and programmatically creates the cluster using the `redis-py` library. No ECS Exec or redis-cli required!

## Prerequisites

- **Terraform** >= 1.0
- **Python** >= 3.9 (for building Lambda layer)
- **pip** (Python package manager)
- **AWS CLI** configured with appropriate credentials
- **VPC** with subnets (private subnets recommended)

## Step 1: Configure Your Module

Create a `main.tf` file:

```hcl
module "redis_cluster" {
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

  cluster_name = "my-redis-cluster"
  vpc_id       = "vpc-xxxxx"        # Your VPC ID
  subnet_ids   = [                   # Your subnet IDs (3 recommended)
    "subnet-xxxxx",
    "subnet-yyyyy",
    "subnet-zzzzz"
  ]
  aws_region   = "us-east-1"

  # Redis cluster configuration
  redis_master_count  = 3  # Minimum 3 for Redis Cluster
  redis_replica_count = 3  # 1 replica per master

  # Network configuration
  allowed_cidr_blocks = ["10.0.0.0/16"]  # Your VPC CIDR or application CIDR

  # Automatic initialization (enabled by default)
  enable_cluster_init = true

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

output "redis_endpoint" {
  value = module.redis_cluster.redis_endpoints
}
```

## Step 2: Initialize Terraform

```bash
terraform init
```

This downloads the module and initializes providers.

## Step 3: Build Lambda Layer (First Time Only)

The Lambda function needs the `redis-py` library. Build the layer:

```bash
# This creates lambda/layer/ with Python dependencies
bash lambda/build_layer.sh
```

**What this does:**
- Creates `lambda/layer/python/` directory
- Installs `redis>=4.5.0` and `boto3>=1.26.0`
- Packages them for Lambda layer

**Note:** This is automatically done by Terraform during `terraform apply`, but you can run it manually first if you prefer.

## Step 4: Deploy

```bash
terraform plan  # Review what will be created
terraform apply # Deploy the infrastructure
```

### What Gets Created

1. **ECS Cluster** - Container platform
2. **ECS Service** - Manages 6 tasks (3 masters + 3 replicas)
3. **CloudMap** - Service discovery (`redis-cluster.redis.local`)
4. **Security Groups** - Ports 6379 + 16379
5. **Lambda Layer** - With redis-py library
6. **Lambda Function** - Cluster initialization
7. **CloudWatch Event** - Triggers Lambda when service is ready
8. **IAM Roles** - Proper permissions

### Timeline

- **0-2 min**: Terraform creates resources
- **2-5 min**: ECS tasks start and register with CloudMap
- **5-7 min**: Lambda automatically initializes cluster
- **7 min**: ✅ Cluster ready!

## Step 5: Monitor Progress

### Watch ECS Service

```bash
watch aws ecs describe-services \
  --cluster my-redis-cluster-redis \
  --services my-redis-cluster-redis-service \
  --region us-east-1 \
  --query 'services[0].{Running:runningCount,Desired:desiredCount,Status:status}'
```

Wait until: `Running == Desired == 6`

### Watch Lambda Logs

```bash
aws logs tail /aws/lambda/my-redis-cluster-redis-cluster-init \
  --follow \
  --region us-east-1
```

### Expected Lambda Output

```
Event: {"detail": {"eventName": "SERVICE_STEADY_STATE", ...}}
Cluster configuration: 3 masters, 3 replicas (1 per master)
Checking ECS service status...
Service status: running=6, desired=6
All tasks running, waiting for health checks...
Discovering Redis nodes...
Found 6 Redis nodes: ['10.0.1.10', '10.0.1.11', '10.0.1.12', '10.0.1.13', '10.0.1.14', '10.0.1.15']
Task ARNs: ['arn:aws:ecs:...', ...]
Checking cluster status on 10.0.1.10...
Creating cluster with nodes: ['10.0.1.10', '10.0.1.11', ...]
Replicas per master: 1
Making nodes meet each other...
Node 10.0.1.10 met 10.0.1.11
Node 10.0.1.10 met 10.0.1.12
...
Waiting for cluster gossip to propagate...
Assigning hash slots...
Assigning slots 0-5460 to node 10.0.1.10 (ID: abc123...)
Assigning slots 5461-10922 to node 10.0.1.11 (ID: def456...)
Assigning slots 10923-16383 to node 10.0.1.12 (ID: ghi789...)
Setting up replication...
Making 10.0.1.13 a replica of 10.0.1.10 (ID: abc123...)
Making 10.0.1.14 a replica of 10.0.1.11 (ID: def456...)
Making 10.0.1.15 a replica of 10.0.1.12 (ID: ghi789...)
Cluster info: cluster_state:ok...
Cluster created successfully!
Redis cluster initialized successfully!
```

## Step 6: Verify Cluster

### From Within VPC

If you have a bastion host or EC2 instance in the VPC:

```bash
# Get any node IP
NODE_IP=$(aws ecs describe-tasks \
  --cluster my-redis-cluster-redis \
  --tasks $(aws ecs list-tasks \
    --cluster my-redis-cluster-redis \
    --service-name my-redis-cluster-redis-service \
    --query 'taskArns[0]' --output text) \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' \
  --output text)

# Check cluster status
redis-cli -h $NODE_IP cluster info

# Expected output:
# cluster_state:ok
# cluster_slots_assigned:16384
# cluster_slots_ok:16384
# cluster_known_nodes:6
# cluster_size:3

# View all nodes
redis-cli -h $NODE_IP cluster nodes
```

### Via CloudMap DNS

```bash
# Test DNS resolution
dig redis-cluster.redis.local +short

# Should return all 6 node IPs
```

## Step 7: Connect Your Application

### Python

```python
from redis.cluster import RedisCluster

# Connect using CloudMap DNS
cluster = RedisCluster(
    host='redis-cluster.redis.local',
    port=6379,
    decode_responses=True
)

# Test it
cluster.set('test', 'Hello from Redis Cluster!')
print(cluster.get('test'))  # Output: Hello from Redis Cluster!

# The client automatically discovers all nodes
print(cluster.get_nodes())
```

### Node.js

```javascript
const Redis = require('ioredis');

const cluster = new Redis.Cluster([
  { host: 'redis-cluster.redis.local', port: 6379 }
]);

cluster.set('test', 'Hello from Redis Cluster!');
cluster.get('test', (err, result) => {
  console.log(result);  // Output: Hello from Redis Cluster!
});
```

### Go

```go
import (
    "github.com/go-redis/redis/v8"
    "context"
)

func main() {
    ctx := context.Background()

    client := redis.NewClusterClient(&redis.ClusterOptions{
        Addrs: []string{"redis-cluster.redis.local:6379"},
    })

    client.Set(ctx, "test", "Hello from Redis Cluster!", 0)
    val, _ := client.Get(ctx, "test").Result()
    println(val)  // Output: Hello from Redis Cluster!
}
```

## Troubleshooting

### Issue: Lambda Layer Build Fails

**Symptom:**
```
pip: command not found
```

**Solution:**
```bash
# Install Python and pip
# On macOS:
brew install python3

# On Ubuntu:
sudo apt-get install python3-pip

# On Amazon Linux:
sudo yum install python3-pip

# Then rebuild
bash lambda/build_layer.sh
```

### Issue: Lambda Timeout

**Symptom:**
```
Task timed out after 300.00 seconds
```

**Solution:**
1. Check VPC networking (NAT Gateway, Security Groups)
2. Increase Lambda timeout in `main.tf`:
```hcl
timeout = 600  # 10 minutes
```

### Issue: Cannot Connect to Redis Nodes

**Symptom:**
```
Cannot connect to Redis at 10.0.1.10:6379
```

**Causes & Solutions:**

1. **Security Group Issues**
   - Verify Lambda SG can reach Redis SG on port 6379
   - Check `self` rule is enabled for cluster bus (port 16379)

2. **Subnet Issues**
   - Lambda must be in same VPC as Redis tasks
   - If using private subnets, ensure NAT Gateway exists

3. **Task Not Ready**
   - Lambda triggered too early
   - Wait times built into function should handle this

### Issue: redis-py Not Found

**Symptom:**
```
ImportError: No module named 'redis'
```

**Solution:**
1. Rebuild Lambda layer:
```bash
bash lambda/build_layer.sh
```

2. Ensure `null_resource.build_lambda_layer` ran:
```bash
terraform taint 'null_resource.build_lambda_layer[0]'
terraform apply
```

### Issue: Cluster Already Initialized

**Symptom:**
```
Redis cluster is already initialized
```

**Action:**
This is normal! Lambda detected cluster is ready. No action needed.

### Manual Fallback

If Lambda initialization fails, you can initialize manually:

```bash
# Run the init script
export ECS_CLUSTER="my-redis-cluster-redis"
export ECS_SERVICE="my-redis-cluster-redis-service"
export MASTER_COUNT=3
export REPLICA_COUNT=3
export AWS_REGION="us-east-1"

./scripts/init-cluster.sh
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

This removes:
- All ECS tasks and services
- Lambda function and layer
- Security groups
- CloudMap namespace
- IAM roles
- CloudWatch logs (after retention period)

## Cost Summary

Approximate monthly costs (us-east-1):

| Resource | Configuration | Monthly Cost |
|----------|---------------|-------------|
| ECS Tasks | 6 tasks × 0.5 vCPU × 1GB | ~$60-80 |
| Lambda | 2-3 executions | ~$0.0001 |
| CloudWatch Logs | 7 days retention | ~$1-2 |
| **Total** | | **~$65-85/month** |

## Production Checklist

Before going to production:

- [ ] Use private subnets with NAT Gateway
- [ ] Configure appropriate `allowed_cidr_blocks`
- [ ] Enable Container Insights for monitoring
- [ ] Set appropriate log retention
- [ ] Configure CloudWatch alarms
- [ ] Document connection strings for applications
- [ ] Test failover scenarios
- [ ] Plan backup strategy (if persistence needed)
- [ ] Review security group rules
- [ ] Tag all resources appropriately

## Next Steps

1. **Connect Your Application** - Use CloudMap DNS endpoint
2. **Set Up Monitoring** - CloudWatch dashboards and alarms
3. **Load Testing** - Test with realistic traffic
4. **Documentation** - Document for your team
5. **Backup Strategy** - Consider EFS for persistence

## Getting Help

- **Lambda Logs**: `/aws/lambda/<cluster-name>-redis-cluster-init`
- **ECS Logs**: `/ecs/<cluster-name>-redis`
- **Documentation**: See [LAMBDA_INIT_GUIDE.md](LAMBDA_INIT_GUIDE.md)
- **Issues**: [GitHub Issues](https://github.com/kamranbiglari/terraform-aws-containerize-redis/issues)

## Additional Resources

- [LAMBDA_INIT_GUIDE.md](LAMBDA_INIT_GUIDE.md) - Lambda initialization details
- [CLUSTER_INIT.md](CLUSTER_INIT.md) - All initialization methods
- [ARCHITECTURE.md](ARCHITECTURE.md) - Technical architecture
- [README.md](README.md) - Complete module documentation
