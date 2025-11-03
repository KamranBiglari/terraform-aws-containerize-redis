provider "aws" {
  region = var.aws_region
}

# VPC and Networking (example - use your existing VPC)
data "aws_vpc" "existing" {
  id = var.vpc_id
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }

  tags = {
    Type = "private"
  }
}

# Redis Cluster Module
module "redis_cluster" {
  source = "../.."

  cluster_name                = var.cluster_name
  vpc_id                      = var.vpc_id
  subnet_ids                  = var.subnet_ids
  aws_region                  = var.aws_region

  # Redis Cluster Configuration
  redis_master_count   = 3  # Minimum 3 masters for Redis cluster
  redis_replica_count  = 3  # 3 replicas (1 per master)
  redis_image          = "redis:7.2-alpine"

  # Task Configuration
  task_cpu    = 512
  task_memory = 1024

  # Network Configuration
  assign_public_ip    = false  # Use private subnets
  allowed_cidr_blocks = [data.aws_vpc.existing.cidr_block]

  # CloudMap Configuration
  service_discovery_namespace = "redis.local"

  # Optional Features
  enable_container_insights = true
  enable_ecs_exec          = true   # Enable for debugging
  enable_cluster_init      = true   # Enable automatic cluster initialization
  log_retention_days       = 7

  tags = {
    Environment = "production"
    Project     = "redis-cluster"
    ManagedBy   = "terraform"
  }
}

# Output the Redis endpoints
output "redis_cluster_endpoint" {
  description = "Redis cluster endpoint for applications"
  value       = module.redis_cluster.redis_endpoints
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.redis_cluster.ecs_cluster_name
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for Redis logs"
  value       = module.redis_cluster.cloudwatch_log_group_name
}
