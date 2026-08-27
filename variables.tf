variable "cluster_name" {
  description = "Name prefix for the Redis cluster resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where Redis cluster will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for Redis tasks (use private subnets)"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to connect to Redis cluster"
  type        = list(string)
  default     = []
}

variable "redis_port" {
  description = "Port for Redis"
  type        = number
  default     = 6379

  validation {
    condition     = var.redis_port > 0 && var.redis_port < 65536
    error_message = "Redis port must be between 1 and 65535."
  }
}

variable "redis_cluster_port" {
  description = "Port for the Redis Cluster bus. Defaults to `redis_port` + 10000, which is the offset Redis itself uses when `cluster-port` is unset."
  type        = number
  default     = null

  validation {
    condition     = var.redis_cluster_port == null || (var.redis_cluster_port > 0 && var.redis_cluster_port < 65536)
    error_message = "Redis cluster port must be between 1 and 65535."
  }
}

variable "redis_master_count" {
  description = "Number of Redis master nodes in the cluster"
  type        = number
  default     = 3

  validation {
    condition     = var.redis_master_count >= 3
    error_message = "Redis cluster requires at least 3 master nodes."
  }
}

variable "redis_replica_count" {
  description = "Number of Redis replica nodes (total replicas, not per master)"
  type        = number
  default     = 3

  validation {
    condition     = var.redis_replica_count >= 0
    error_message = "Redis replica count must be non-negative."
  }
}

variable "redis_image" {
  description = "Docker image for Redis (must support cluster mode)"
  type        = string
  default     = "redis:7.2-alpine"
}

variable "task_cpu" {
  description = "CPU units for Redis task (1024 = 1 vCPU)"
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.task_cpu)
    error_message = "Valid values for task_cpu: 256, 512, 1024, 2048, 4096."
  }
}

variable "task_memory" {
  description = "Memory for Redis task in MB"
  type        = number
  default     = 1024

  validation {
    condition = (
      (var.task_cpu == 256 && contains([512, 1024, 2048], var.task_memory)) ||
      (var.task_cpu == 512 && contains([1024, 2048, 3072, 4096], var.task_memory)) ||
      (var.task_cpu == 1024 && contains([2048, 3072, 4096, 5120, 6144, 7168, 8192], var.task_memory)) ||
      (var.task_cpu == 2048 && var.task_memory >= 4096 && var.task_memory <= 16384) ||
      (var.task_cpu == 4096 && var.task_memory >= 8192 && var.task_memory <= 30720)
    )
    error_message = "Task memory must be compatible with task CPU. See AWS Fargate task size documentation."
  }
}

variable "service_discovery_namespace" {
  description = "CloudMap namespace for service discovery"
  type        = string
  default     = "redis.local"
}


variable "service_discovery_name" {
  description = "CloudMap service name for Redis"
  type        = string
  default     = "redis-cluster"
}

variable "assign_public_ip" {
  description = "Assign public IP to tasks (set to true if using public subnets)"
  type        = bool
  default     = false
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights for the ECS cluster"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "Invalid log retention days. Must be a valid CloudWatch Logs retention period."
  }
}

variable "enable_ecs_exec" {
  description = "Enable ECS Exec for debugging tasks"
  type        = bool
  default     = false
}

variable "enable_cluster_init" {
  description = "Enable automatic cluster initialization using Lambda via ECS Exec (automatically enables ECS Exec on the service)"
  type        = bool
  default     = true
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = null
}

variable "redis_environment_variables" {
  description = "Additional environment variables for Redis containers"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "ecs_service_config_tags" {
  description = "Tags to apply to aws ecs service"
  type        = map(string)
  default = {
    "desired_count" = "Config:desiredCount"
  }
}

variable "create_ecs_cluster" {
  description = "Whether to create a new ECS cluster for the Redis service. Set to false to deploy into an existing cluster provided via `existing_ecs_cluster_arn`."
  type        = bool
  default     = true
}

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster to create. Only used when `create_ecs_cluster` is true. Defaults to `\"<cluster_name>-redis\"`."
  type        = string
  default     = null
}

variable "existing_ecs_cluster_arn" {
  description = "ARN of an existing ECS cluster to deploy the Redis service into. Required when `create_ecs_cluster` is false, ignored otherwise."
  type        = string
  default     = null
}

variable "create_cloudwatch_log_group" {
  description = "Whether to create a CloudWatch log group for the Redis tasks. Set to false to log into an existing group provided via `existing_cloudwatch_log_group_name`."
  type        = bool
  default     = true
}

variable "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group to create. Only used when `create_cloudwatch_log_group` is true. Defaults to `\"/ecs/<cluster_name>-redis\"`."
  type        = string
  default     = null
}

variable "existing_cloudwatch_log_group_name" {
  description = "Name of an existing CloudWatch log group to send Redis task logs to. Required when `create_cloudwatch_log_group` is false, ignored otherwise."
  type        = string
  default     = null
}
