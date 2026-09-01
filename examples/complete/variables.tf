variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the Redis cluster"
  type        = string
  default     = "my-redis-cluster"
}

variable "vpc_id" {
  description = "VPC ID where Redis will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs (use private subnets)"
  type        = list(string)
}

variable "redis_password" {
  description = "Password for the Redis cluster. Left null, the module generates one and stores it in Secrets Manager."
  type        = string
  default     = null
  sensitive   = true
}
