# Lambda-Based Automatic Cluster Initialization

This guide explains how the Lambda-based automatic initialization works and how to use it.

## How It Works

The Lambda function automatically initializes your Redis cluster after all ECS tasks are running:

1. **CloudWatch Event** triggers when ECS service reaches steady state
2. **Lambda function** is invoked automatically
3. **Discovery**: Lambda discovers all Redis node IPs via ECS API
4. **Execution**: Lambda uses ECS Exec to run `redis-cli --cluster create` on one of the tasks
5. **Verification**: Lambda verifies the cluster is healthy

## Architecture

```
ECS Service (All tasks running)
        ↓
CloudWatch Event (SERVICE_STEADY_STATE)
        ↓
Lambda Function
        ↓
    ┌───┴────┐
    │ Step 1 │ Wait for all tasks running
    └───┬────┘
        ↓
    ┌───┴────┐
    │ Step 2 │ Get all task IPs from ECS
    └───┬────┘
        ↓
    ┌───┴────┐
    │ Step 3 │ Check if already initialized
    └───┬────┘
        ↓
    ┌───┴────┐
    │ Step 4 │ ECS Exec: redis-cli --cluster create
    └───┬────┘
        ↓
    ┌───┴────┐
    │ Step 5 │ Verify cluster_state:ok
    └───┬────┘
        ↓
  Cluster Ready! ✅
```

## Prerequisites

The Lambda-based initialization requires:

1. ✅ **ECS Exec enabled**: Automatically enabled when `enable_cluster_init = true`
2. ✅ **IAM Permissions**: Automatically configured by the module
3. ✅ **VPC Access**: Lambda is placed in same VPC as Redis tasks
4. ✅ **SSM Agent**: Built into Fargate platform version 1.4.0+

## Configuration

### Enable Lambda Initialization (Default)

```hcl
module "redis_cluster" {
  source = "github.com/kamranbiglari/terraform-aws-containerize-redis"

  cluster_name = "my-redis"
  vpc_id       = "vpc-xxxxx"
  subnet_ids   = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
  aws_region   = "us-east-1"

  redis_master_count  = 3
  redis_replica_count = 3

  # Lambda initialization is enabled by default
  enable_cluster_init = true  # This is the default

  # ECS Exec is automatically enabled when enable_cluster_init = true
  # You can also enable it explicitly for debugging:
  # enable_ecs_exec = true
}
```

### Disable Lambda Initialization

If you prefer manual initialization:

```hcl
enable_cluster_init = false
```

Then use the shell script or manual methods described in [CLUSTER_INIT.md](CLUSTER_INIT.md).

## Deployment Flow

1. **terraform apply** creates all resources including Lambda
2. **ECS service** starts all tasks (~2-3 minutes)
3. **Tasks register** with CloudMap
4. **Service reaches steady state**
5. **CloudWatch Event** triggers Lambda
6. **Lambda initializes cluster** (~2-3 minutes)
7. **Cluster ready** for use

**Total time: ~5-7 minutes**

## Monitoring

### Check Lambda Execution

```bash
# View Lambda logs
aws logs tail /aws/lambda/<cluster-name>-redis-cluster-init --follow

# Check Lambda invocations
aws lambda list-invocations \
  --function-name <cluster-name>-redis-cluster-init \
  --region <region>
```

### Expected Log Output

```
Event: {"detail": {"eventName": "SERVICE_STEADY_STATE", ...}}
Cluster configuration: 3 masters, 3 replicas (1 per master)
Checking ECS service status...
Service status: running=6, desired=6
All tasks running, waiting for health checks...
Discovering Redis nodes...
Found 6 Redis nodes: ['10.0.1.10', '10.0.1.11', ...]
Task ARNs: ['arn:aws:ecs:...', ...]
Executing command on task arn:aws:ecs:...: redis-cli cluster info
Started ECS Exec session: ecs-execute-command-...
Waiting 30 seconds for command to complete...
Command execution completed
Initializing Redis cluster...
Running command: redis-cli --cluster create 10.0.1.10:6379 10.0.1.11:6379 ...
Started ECS Exec session: ecs-execute-command-...
Waiting 120 seconds for command to complete...
Cluster verification: cluster_state:ok
Redis cluster initialized successfully!
```

## Troubleshooting

### Issue: Lambda Times Out

**Symptom:**
```
Task timed out after 300.00 seconds
```

**Solution:**
- Increase Lambda timeout (currently 300 seconds)
- Check VPC networking (NAT Gateway, Security Groups)
- Verify tasks are reachable from Lambda

### Issue: AccessDeniedException

**Symptom:**
```
User is not authorized to perform: ecs:ExecuteCommand
```

**Solution:**
This should not happen with the latest module. If it does:
1. Run `terraform apply` to update IAM policies
2. Verify `enable_cluster_init = true`
3. Check Lambda IAM role has `ecs:ExecuteCommand` permission

### Issue: Cluster Already Initialized

**Symptom:**
```
Redis cluster is already initialized
```

**Action:**
This is normal! Lambda detected cluster is already running. No action needed.

### Issue: Command Execution Fails

**Symptom:**
```
Error executing command: An error occurred
```

**Debugging Steps:**

1. **Check ECS Exec is enabled:**
```bash
aws ecs describe-services \
  --cluster <cluster-name>-redis \
  --services <cluster-name>-redis-service \
  --query 'services[0].enableExecuteCommand'
```
Should return: `true`

2. **Manually test ECS Exec:**
```bash
TASK_ID=$(aws ecs list-tasks \
  --cluster <cluster-name>-redis \
  --service-name <cluster-name>-redis-service \
  --query 'taskArns[0]' \
  --output text | awk -F/ '{print $NF}')

aws ecs execute-command \
  --cluster <cluster-name>-redis \
  --task $TASK_ID \
  --container redis \
  --interactive \
  --command "redis-cli ping"
```

3. **Check Lambda VPC configuration:**
```bash
aws lambda get-function-configuration \
  --function-name <cluster-name>-redis-cluster-init \
  --query 'VpcConfig'
```
Should show same VPC and subnets as Redis tasks.

### Issue: Nodes Can't Communicate

**Symptom:**
```
Cluster creation failed: nodes cannot join
```

**Solution:**
- Verify Security Group allows traffic on ports 6379 and 16379
- Check `self` rule is enabled on Security Group
- Ensure all tasks are in same VPC

## Manual Verification

After Lambda completes, verify the cluster:

```bash
# Get a task IP
TASK_IP=$(aws ecs describe-tasks \
  --cluster <cluster-name>-redis \
  --tasks $(aws ecs list-tasks \
    --cluster <cluster-name>-redis \
    --service-name <cluster-name>-redis-service \
    --query 'taskArns[0]' --output text) \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' \
  --output text)

# Check cluster info (from within VPC)
redis-cli -h $TASK_IP cluster info

# Should show:
# cluster_state:ok
# cluster_slots_assigned:16384
# cluster_known_nodes:6
```

## Lambda Function Details

### Permissions Required

The Lambda function needs:
- ✅ `ecs:DescribeServices` - Check service status
- ✅ `ecs:ListTasks` - List running tasks
- ✅ `ecs:DescribeTasks` - Get task IPs
- ✅ `ecs:ExecuteCommand` - Run commands via ECS Exec
- ✅ `ssm:StartSession` - Start SSM session for ECS Exec
- ✅ `ec2:DescribeNetworkInterfaces` - Get network info
- ✅ VPC access permissions (automatically added)

All automatically configured by the module!

### Environment Variables

Lambda receives:
- `ECS_CLUSTER_ARN` - Full cluster ARN
- `ECS_SERVICE_NAME` - Service name
- `REDIS_MASTER_COUNT` - Number of masters
- `REDIS_REPLICA_COUNT` - Number of replicas
- `CLOUDMAP_NAMESPACE` - CloudMap namespace
- `CLOUDMAP_SERVICE` - CloudMap service name

### Timeout Settings

- **Lambda timeout**: 300 seconds (5 minutes)
- **Command wait time**: 120 seconds for cluster create
- **Verification wait**: 30 seconds for checks

## Advantages of Lambda Initialization

### ✅ Pros

1. **Fully Automatic** - No manual intervention required
2. **Event-Driven** - Triggers when service is ready
3. **Idempotent** - Can run multiple times safely
4. **Serverless** - No infrastructure to manage
5. **Cost-Effective** - Only charged for execution time (~2-3 invocations)

### ⚠️ Considerations

1. **Requires ECS Exec** - Automatically enabled by module
2. **VPC Networking** - Lambda must reach tasks (same VPC)
3. **First-Time Setup** - May take 5-7 minutes total
4. **Debugging** - Check CloudWatch Logs for issues

## Cost Estimate

Lambda-based initialization costs:
- **Lambda execution**: ~$0.0001 per invocation
- **ECS Exec overhead**: Minimal (included in Fargate pricing)
- **CloudWatch Events**: Free for AWS service events

**Total additional cost: < $0.01 per cluster deployment**

## Comparison with Manual Initialization

| Aspect | Lambda Auto-Init | Manual Script |
|--------|------------------|---------------|
| **Automation** | ✅ Fully automatic | Manual trigger |
| **Network Access** | ✅ Same VPC | Requires VPC access |
| **Setup Time** | 5-7 minutes | 2-3 minutes after tasks start |
| **Debugging** | CloudWatch Logs | Direct output |
| **Dependencies** | None (all included) | redis-cli, AWS CLI |
| **Cost** | < $0.01 | Free (your time) |
| **Recommended For** | Production | Development/Testing |

## When to Use Lambda Init

**Use Lambda initialization when:**
- ✅ You want fully automated deployment
- ✅ You're deploying via CI/CD pipelines
- ✅ You don't have local redis-cli available
- ✅ You prefer hands-off infrastructure

**Use manual initialization when:**
- ⚠️ You need immediate feedback
- ⚠️ You're debugging cluster issues
- ⚠️ You want full control over timing
- ⚠️ You prefer simpler troubleshooting

## Best Practices

1. **Monitor First Deployment**: Watch CloudWatch Logs the first time
2. **Test in Dev First**: Verify Lambda init works in non-prod
3. **Keep Default Settings**: Lambda timeout and wait times are optimized
4. **Enable CloudWatch Insights**: For better observability
5. **Document Custom Changes**: If you modify Lambda function

## Related Documentation

- [CLUSTER_INIT.md](CLUSTER_INIT.md) - All initialization methods
- [README.md](README.md) - Main module documentation
- [ARCHITECTURE.md](ARCHITECTURE.md) - Detailed architecture
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Common issues

## Support

For issues with Lambda initialization:

1. Check CloudWatch Logs: `/aws/lambda/<cluster-name>-redis-cluster-init`
2. Review this guide's troubleshooting section
3. Try manual initialization as fallback
4. Open GitHub issue with logs if problem persists
