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
  description = "Enable automatic cluster initialization using Lambda"
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
