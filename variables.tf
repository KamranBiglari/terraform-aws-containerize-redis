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

variable "create_service_discovery_namespace" {
  description = "Whether to create a CloudMap private DNS namespace. Set to false to register the Redis service in an existing namespace provided via `existing_service_discovery_namespace_name`."
  type        = bool
  default     = true
}

variable "service_discovery_namespace" {
  description = "Name of the CloudMap private DNS namespace to create. Only used when `create_service_discovery_namespace` is true."
  type        = string
  default     = "redis.local"
}

variable "existing_service_discovery_namespace_type" {
  description = "Type of the existing CloudMap namespace to look up: `DNS_PRIVATE` or `DNS_PUBLIC`. Only used when `create_service_discovery_namespace` is false."
  type        = string
  default     = "DNS_PRIVATE"

  validation {
    condition     = contains(["DNS_PRIVATE", "DNS_PUBLIC"], var.existing_service_discovery_namespace_type)
    error_message = "Namespace type must be either DNS_PRIVATE or DNS_PUBLIC."
  }
}

variable "existing_service_discovery_namespace_name" {
  description = "Name of an existing CloudMap private DNS namespace to register the Redis service in. Required when `create_service_discovery_namespace` is false, ignored otherwise. The namespace must already exist when this module is planned."
  type        = string
  default     = null
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
  description = "Whether to create a new ECS cluster for the Redis service. Set to false to deploy into an existing cluster provided via `existing_ecs_cluster_name`."
  type        = bool
  default     = true
}

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster to create. Only used when `create_ecs_cluster` is true. Defaults to `\"<cluster_name>-redis\"`."
  type        = string
  default     = null
}

variable "existing_ecs_cluster_name" {
  description = "Name of an existing ECS cluster to deploy the Redis service into. Required when `create_ecs_cluster` is false, ignored otherwise. The cluster must already exist when this module is planned."
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

variable "cluster_init_timeout" {
  description = "Timeout in seconds for the cluster initialization Lambda. It has to cover waiting for the ECS service to stabilize plus forming the cluster."
  type        = number
  default     = 900

  validation {
    condition     = var.cluster_init_timeout > 0 && var.cluster_init_timeout <= 900
    error_message = "Lambda timeout must be between 1 and 900 seconds."
  }
}

variable "lambda_layer_build_method" {
  description = "How to build the Lambda layer: `docker` builds it in a container matching the Lambda runtime, `python` uses the host's pip, and `auto` prefers Docker and falls back to pip. Docker needs nothing installed beyond Docker itself and is the only option that guarantees Linux/x86_64 wheels."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "docker", "python"], var.lambda_layer_build_method)
    error_message = "Build method must be one of: auto, docker, python."
  }
}

variable "lambda_layer_build_image" {
  description = "Container image used to build the Lambda layer when the build method resolves to Docker."
  type        = string
  default     = "public.ecr.aws/sam/build-python3.11"
}

variable "lambda_layer_build_interpreter" {
  description = "Interpreter used to run `lambda/build_layer.sh`, which builds the Lambda layer. The default needs `bash` on PATH - on Windows, Git Bash satisfies this."
  type        = list(string)
  default     = ["bash", "-c"]
}

variable "service_discovery_deregistration_delay" {
  description = "How long to wait, on destroy, between deleting the ECS service and deleting the CloudMap service, so that task instances finish deregistering. Raise it if destroys fail with `ResourceInUse: Service contains registered instances`."
  type        = string
  default     = "120s"
}

variable "create_redis_password_secret" {
  description = "Whether to create a Secrets Manager secret holding the Redis password. Setting this, or `existing_redis_password_secret_arn`, turns on Redis AUTH; with neither the cluster runs unauthenticated."
  type        = bool
  default     = false
}

variable "redis_password" {
  description = "Password to store in the created secret. Only used when `create_redis_password_secret` is true; when left null a strong password is generated."
  type        = string
  default     = null
  sensitive   = true
}

variable "redis_password_secret_name" {
  description = "Name of the Secrets Manager secret to create. Only used when `create_redis_password_secret` is true. Defaults to `\"<cluster_name>-redis-password\"`."
  type        = string
  default     = null
}

variable "existing_redis_password_secret_arn" {
  description = "ARN of an existing Secrets Manager secret holding the Redis password. Use instead of `create_redis_password_secret` to bring your own secret."
  type        = string
  default     = null
}

variable "existing_redis_password_secret_key" {
  description = "Key to read from an existing JSON-encoded secret, for example `password`. Leave null when the secret's value is the password itself. Only used with `existing_redis_password_secret_arn`."
  type        = string
  default     = null
}
