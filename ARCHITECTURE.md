# Architecture Overview

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                           AWS VPC                                │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Private Subnets                        │  │
│  │                                                            │  │
│  │  ┌─────────────────┐  ┌─────────────────┐               │  │
│  │  │  ECS Fargate    │  │  ECS Fargate    │               │  │
│  │  │  Task (Master 1)│  │  Task (Master 2)│   ...         │  │
│  │  │  Redis 6379     │  │  Redis 6379     │               │  │
│  │  │  Bus 16379      │  │  Bus 16379      │               │  │
│  │  └────────┬────────┘  └────────┬────────┘               │  │
│  │           │                     │                         │  │
│  │  ┌────────┴───────────────────┴────────────────────┐   │  │
│  │  │         CloudMap Service Discovery              │   │  │
│  │  │      redis-cluster.redis.local                  │   │  │
│  │  └─────────────────────────────────────────────────┘   │  │
│  │                                                            │  │
│  │  ┌─────────────────┐  ┌─────────────────┐               │  │
│  │  │  ECS Fargate    │  │  ECS Fargate    │               │  │
│  │  │  Task (Replica 1)│ │  Task (Replica 2)│  ...         │  │
│  │  │  Redis 6379     │  │  Redis 6379     │               │  │
│  │  │  Bus 16379      │  │  Bus 16379      │               │  │
│  │  └─────────────────┘  └─────────────────┘               │  │
│  │                                                            │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │               Lambda Initialization Function              │  │
│  │   (Triggers after service stabilizes to create cluster)   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │   CloudWatch Logs      │
                    │  /ecs/redis-cluster    │
                    └────────────────────────┘
```

## Component Details

### 1. ECS Cluster

**Purpose:** Container orchestration platform for Redis nodes

**Configuration:**
- Launch Type: Fargate (serverless)
- Container Insights: Optional monitoring
- Service: Manages desired number of tasks

**Why Fargate?**
- No EC2 instance management
- Automatic scaling
- Pay only for container resources
- Built-in high availability

### 2. ECS Tasks (Redis Nodes)

Each task runs a single Redis container in cluster mode.

**Task Definition:**
```yaml
Container:
  - Name: redis
    Image: redis:7.2-alpine
    Ports:
      - 6379  (Redis client)
      - 16379 (Cluster bus)
    Command:
      - redis-server
      - --cluster-enabled yes
      - --cluster-config-file nodes.conf
      - --cluster-node-timeout 5000
      - --appendonly yes
      - --protected-mode no
    Health Check:
      - redis-cli ping
```

**Resources:**
- CPU: 256-4096 units (configurable)
- Memory: 512MB-30GB (configurable)
- Storage: Ephemeral (task local)

**Important:** Data is stored in task memory. For persistence, consider adding EFS volumes.

### 3. CloudMap Service Discovery

**Purpose:** Private DNS for inter-node communication

**How it works:**
1. Each ECS task registers with CloudMap on startup
2. CloudMap creates DNS A records: `redis-cluster.redis.local`
3. DNS returns all task IPs (multivalue routing)
4. Redis nodes discover each other via DNS

**Benefits:**
- No hardcoded IPs
- Automatic updates when tasks restart
- Private DNS within VPC
- Low TTL (10 seconds) for fast failover

**DNS Resolution Example:**
```bash
dig redis-cluster.redis.local +short
10.0.1.10
10.0.1.11
10.0.1.12
10.0.1.13
10.0.1.14
10.0.1.15
```

### 4. Security Groups

**Redis Cluster Security Group:**

**Inbound Rules:**
- Port 6379 (TCP) - From `allowed_cidr_blocks`
- Port 16379 (TCP) - From self (inter-node communication)

**Outbound Rules:**
- All traffic to 0.0.0.0/0 (for Docker image pulls)

**Best Practice:**
- Use separate security groups for applications
- Allow application SG → Redis SG on port 6379
- Keep cluster bus (16379) internal only

### 5. Cluster Initialization

Redis Cluster requires initialization to assign hash slots and configure replication.

**Automatic (Lambda-based):**

```
ECS Service Stable Event
         ↓
CloudWatch Event Rule
         ↓
Lambda Function
         ↓
1. Wait for all tasks running
2. Discover node IPs via ECS API
3. Run: redis-cli --cluster create
4. Verify cluster health
```

**Lambda Environment:**
- Runtime: Python 3.11
- VPC: Same as Redis tasks
- Timeout: 5 minutes
- Permissions: ECS describe/list, Service Discovery

**Initialization Command:**
```bash
redis-cli --cluster create \
  10.0.1.10:6379 10.0.1.11:6379 10.0.1.12:6379 \
  10.0.1.13:6379 10.0.1.14:6379 10.0.1.15:6379 \
  --cluster-replicas 1 \
  --cluster-yes
```

### 6. IAM Roles

**ECS Task Execution Role:**
- Pull Docker images from ECR
- Write logs to CloudWatch
- Read secrets from Secrets Manager (if used)

**ECS Task Role:**
- Service Discovery API access
- ECS describe tasks (for init script)

**Lambda Execution Role:**
- VPC network interfaces
- ECS describe/list APIs
- CloudWatch Logs

### 7. Networking Flow

**Inter-Node Communication:**
```
Redis Node 1 (10.0.1.10)
         ↓ (Cluster bus protocol)
    Port 16379
         ↓
Redis Node 2 (10.0.1.11)
```

**Client Communication:**
```
Application (10.0.2.50)
         ↓
DNS Query: redis-cluster.redis.local
         ↓
CloudMap returns: [10.0.1.10, 10.0.1.11, ...]
         ↓
Redis Client connects to any node
         ↓
Redis Cluster redirects to correct shard
```

### 8. Data Distribution

Redis Cluster uses **hash slots** for data distribution:

- Total slots: 16384
- Slots distributed across masters
- Each master owns ~5461 slots (for 3 masters)
- Keys are hashed to determine slot: `CRC16(key) % 16384`

**Example with 3 Masters:**
```
Master 1: Slots 0-5460     (Node 10.0.1.10)
Master 2: Slots 5461-10922 (Node 10.0.1.11)
Master 3: Slots 10923-16383(Node 10.0.1.12)
```

**Replication:**
```
Master 1 → Replica 1
Master 2 → Replica 2
Master 3 → Replica 3
```

### 9. Failure Scenarios

**Task Failure:**
1. ECS detects unhealthy task
2. ECS starts new task in available AZ
3. New task registers with CloudMap
4. Redis Cluster detects new node
5. Replica promoted to master if master failed

**AZ Failure:**
1. All tasks in failed AZ become unreachable
2. ECS starts replacement tasks in healthy AZs
3. Redis Cluster continues with available nodes
4. Automatic failover for failed masters

**Network Partition:**
1. Cluster detects partition (node timeout)
2. Majority side continues operating
3. Minority side stops accepting writes
4. Cluster heals when partition resolves

### 10. Monitoring & Logging

**CloudWatch Logs:**
- Log Group: `/ecs/<cluster-name>-redis`
- Log Streams: One per task
- Contains: Redis server logs, cluster events, errors

**Container Insights (Optional):**
- CPU utilization
- Memory utilization
- Network I/O
- Task-level metrics

**Redis Metrics to Monitor:**
- `cluster_state` - Should be "ok"
- `cluster_slots_assigned` - Should be 16384
- `cluster_known_nodes` - Should equal total nodes
- `connected_clients` - Active connections
- `used_memory` - Memory usage
- `evicted_keys` - Memory pressure indicator

**Recommended CloudWatch Alarms:**
- Task count < desired count
- CPU > 80%
- Memory > 80%
- Cluster state != ok
- Connected clients > threshold

## Deployment Flow

```
1. terraform apply
         ↓
2. Create VPC resources (SG, CloudMap)
         ↓
3. Create ECS cluster
         ↓
4. Create IAM roles
         ↓
5. Register task definition
         ↓
6. Create ECS service
         ↓
7. Service starts tasks
         ↓
8. Tasks register with CloudMap
         ↓
9. All tasks running & healthy
         ↓
10. Lambda triggered (if enabled)
         ↓
11. Lambda initializes cluster
         ↓
12. Cluster ready for traffic
```

**Time:** ~5-7 minutes

## Scaling Considerations

### Vertical Scaling (Task Size)

Increase task CPU/memory for more performance per node:

```hcl
task_cpu    = 1024  # 1 vCPU
task_memory = 2048  # 2GB
```

**When to scale vertically:**
- High memory usage per node
- CPU bottleneck on individual nodes
- Large dataset per shard

### Horizontal Scaling (Add Nodes)

Add more master nodes for data distribution:

```hcl
redis_master_count  = 5  # More shards
redis_replica_count = 5  # More replicas
```

**When to scale horizontally:**
- Dataset too large for current shards
- Need higher throughput
- Want better availability

**Important:** Adding masters requires resharding (manual process)

### Multi-AZ Deployment

Deploy across multiple AZs for high availability:

```hcl
subnet_ids = [
  "subnet-xxxxx",  # AZ 1
  "subnet-yyyyy",  # AZ 2
  "subnet-zzzzz"   # AZ 3
]
```

ECS automatically distributes tasks across AZs.

## Security Best Practices

1. **Network Isolation**
   - Deploy in private subnets
   - Use security groups to restrict access
   - No public IPs

2. **Encryption**
   - Consider Redis AUTH password
   - Use TLS for client connections (requires Redis config)
   - Encrypt CloudWatch logs

3. **Access Control**
   - Least privilege IAM roles
   - VPC endpoints for AWS services
   - No hardcoded credentials

4. **Monitoring**
   - Enable CloudTrail for API logging
   - Set up CloudWatch alarms
   - Regular security audits

## Performance Tuning

### Task Resources

**CPU:**
- Start with 512 units (0.5 vCPU)
- Monitor CPU utilization
- Increase if consistently > 70%

**Memory:**
- Size based on dataset
- Leave 20% headroom for overhead
- Monitor eviction rate

### Redis Configuration

Add to `redis_environment_variables`:

```hcl
redis_environment_variables = [
  {
    name  = "REDIS_MAXMEMORY"
    value = "800mb"  # 80% of task memory
  },
  {
    name  = "REDIS_MAXMEMORY_POLICY"
    value = "allkeys-lru"
  }
]
```

### Network Performance

- Use enhanced networking instances types (Fargate default)
- Deploy tasks close to applications (same AZ if possible)
- Monitor network throughput

## Cost Optimization

1. **Right-size Tasks**
   - Start small and scale up
   - Monitor actual usage

2. **Use Spot for Dev/Test**
   - Not directly supported in this module
   - Consider Fargate Spot in future enhancement

3. **Log Retention**
   - Set appropriate retention period
   - Archive old logs to S3

4. **Remove Unused Resources**
   - Clean up old task definitions
   - Remove unused ENIs

## Comparison with Alternatives

### vs. Amazon ElastiCache

**This Module (ECS Fargate):**
- ✅ Full control over configuration
- ✅ Lower cost for small clusters
- ✅ Custom Redis builds
- ❌ Manual cluster management
- ❌ No automatic backups

**ElastiCache:**
- ✅ Managed service
- ✅ Automatic backups
- ✅ Automatic failover
- ❌ Higher cost
- ❌ Less flexibility

### vs. EC2-based Redis

**This Module (ECS Fargate):**
- ✅ No instance management
- ✅ Automatic scaling
- ✅ Built-in high availability
- ❌ Ephemeral storage

**EC2-based:**
- ✅ Persistent storage
- ✅ Instance optimizations
- ❌ Manual instance management
- ❌ Complex autoscaling

## Future Enhancements

Potential improvements:

1. **Persistence**
   - EFS volume for AOF/RDB files
   - Automatic backups to S3

2. **Monitoring Dashboard**
   - CloudWatch dashboard
   - Grafana integration

3. **Automatic Scaling**
   - Auto-scaling based on metrics
   - Predictive scaling

4. **TLS Support**
   - Redis TLS configuration
   - Certificate management

5. **Multi-Region**
   - Cross-region replication
   - Global tables
