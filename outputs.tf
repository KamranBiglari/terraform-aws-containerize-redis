output "ecs_cluster_id" {
  description = "ECS cluster ID"
  value       = aws_ecs_cluster.redis_cluster.id
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.redis_cluster.arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.redis_cluster.name
}

output "ecs_service_id" {
  description = "ECS service ID"
  value       = aws_ecs_service.redis_cluster.id
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.redis_cluster.name
}

output "security_group_id" {
  description = "Security group ID for Redis cluster"
  value       = aws_security_group.redis_cluster.id
}

output "cloudmap_namespace_id" {
  description = "CloudMap namespace ID"
  value       = aws_service_discovery_private_dns_namespace.redis.id
}

output "cloudmap_namespace_name" {
  description = "CloudMap namespace name"
  value       = aws_service_discovery_private_dns_namespace.redis.name
}

output "cloudmap_service_id" {
  description = "CloudMap service ID"
  value       = aws_service_discovery_service.redis.id
}

output "cloudmap_service_name" {
  description = "CloudMap service name"
  value       = aws_service_discovery_service.redis.name
}

output "redis_endpoints" {
  description = "Redis cluster endpoints (use CloudMap DNS for discovery)"
  value       = "${aws_service_discovery_service.redis.name}.${aws_service_discovery_private_dns_namespace.redis.name}"
}

output "redis_port" {
  description = "Redis port"
  value       = 6379
}

output "redis_cluster_port" {
  description = "Redis cluster bus port"
  value       = 16379
}

output "task_definition_arn" {
  description = "ECS task definition ARN"
  value       = aws_ecs_task_definition.redis_node.arn
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.redis.name
}

output "lambda_function_name" {
  description = "Lambda function name for cluster initialization"
  value       = var.enable_cluster_init ? aws_lambda_function.redis_cluster_init[0].function_name : null
}

output "total_nodes" {
  description = "Total number of Redis nodes (masters + replicas)"
  value       = var.redis_master_count + var.redis_replica_count
}

output "master_count" {
  description = "Number of master nodes"
  value       = var.redis_master_count
}

output "replica_count" {
  description = "Number of replica nodes"
  value       = var.redis_replica_count
}
