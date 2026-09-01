provider "aws" {
  region = var.aws_region
}

# Existing VPC, used here only to allow its CIDR range to reach Redis
data "aws_vpc" "existing" {
  id = var.vpc_id
}

# Redis Cluster Module
module "redis_cluster" {
  source = "../.."

  # Basic Configuration
  cluster_name = var.cluster_name
  vpc_id       = var.vpc_id
  subnet_ids   = var.subnet_ids
  aws_region   = var.aws_region

  # Redis Cluster Configuration
  redis_master_count  = 3 # Minimum 3 masters for Redis cluster
  redis_replica_count = 3 # 3 replicas (1 per master)
  redis_image         = "redis:7.2-alpine"

  # Ports. redis_cluster_port defaults to redis_port + 10000, which is the offset
  # Redis itself uses, so it only needs setting to pin a specific bus port.
  redis_port = 6379

  # Task Configuration
  task_cpu    = 512
  task_memory = 1024

  # Network Configuration
  assign_public_ip = false # Use private subnets
  # With enable_cluster_init = true these rules are applied by the initialization
  # Lambda once the cluster is healthy, not during apply.
  allowed_cidr_blocks = [data.aws_vpc.existing.cidr_block]

  # ECS cluster: created here, or set create_ecs_cluster = false and pass
  # existing_ecs_cluster_name to deploy into a cluster you already run.
  create_ecs_cluster = true
  ecs_cluster_name   = "${var.cluster_name}-redis"

  # CloudWatch logs: created here, or set create_cloudwatch_log_group = false and
  # pass existing_cloudwatch_log_group_name.
  create_cloudwatch_log_group = true
  log_retention_days          = 7

  # Service discovery: created here, or set create_service_discovery_namespace =
  # false and pass existing_service_discovery_namespace_name (plus _type for a
  # public namespace).
  create_service_discovery_namespace = true
  service_discovery_namespace        = "redis.local"
  service_discovery_name             = "redis-cluster"

  # Authentication. Omit both of these for an unauthenticated cluster. The created
  # secret holds a connection document: host, port, password and type.
  create_redis_password_secret = true
  # redis_password             = var.redis_password  # generated when not supplied

  # Or bring your own secret instead:
  # existing_redis_password_secret_arn = aws_secretsmanager_secret.redis.arn
  # existing_redis_password_secret_key = "password"

  # Cluster initialization. The Lambda runs on every deployment: it closes client
  # access, waits for the service, verifies the nodes are empty, forms the cluster
  # and reopens access.
  enable_cluster_init  = true
  cluster_init_timeout = 900

  # The Lambda layer is built during apply. "auto" uses Docker when available and
  # falls back to the host's pip; "docker" fails instead of falling back.
  lambda_layer_build_method = "auto"

  # Extra time on destroy for CloudMap instances to deregister before the service
  # discovery service is deleted.
  service_discovery_deregistration_delay = "120s"

  # Optional Features
  enable_container_insights = true
  enable_ecs_exec           = true # Enable for debugging

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
    Project     = "redis-cluster"
    ManagedBy   = "terraform"
  }
}

output "redis_cluster_endpoint" {
  description = "Redis cluster endpoint for applications"
  value       = module.redis_cluster.redis_endpoints
}

output "redis_port" {
  description = "Port clients connect to"
  value       = module.redis_cluster.redis_port
}

output "redis_password_secret_arn" {
  description = "Secret holding host, port, password and type for the cluster"
  value       = module.redis_cluster.redis_password_secret_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.redis_cluster.ecs_cluster_name
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for Redis logs"
  value       = module.redis_cluster.cloudwatch_log_group_name
}
