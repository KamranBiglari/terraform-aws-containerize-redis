locals {
  redis_port = var.redis_port

  # Redis binds the cluster bus at redis_port + 10000 unless cluster-port overrides it,
  # so the default here has to track redis_port rather than being a fixed 16379.
  redis_cluster_port = coalesce(var.redis_cluster_port, var.redis_port + 10000)
  total_nodes        = var.redis_master_count + var.redis_replica_count
  redis_nodes        = [for i in range(local.total_nodes) : "redis-node-${i}"]
  aws_region         = var.aws_region != null ? var.aws_region : data.aws_region.current.name

  # Cluster the Redis service runs on: either the one this module creates or an existing one
  ecs_cluster_arn  = var.create_ecs_cluster ? aws_ecs_cluster.redis_cluster[0].arn : data.aws_ecs_cluster.existing[0].arn
  ecs_cluster_name = var.create_ecs_cluster ? aws_ecs_cluster.redis_cluster[0].name : var.existing_ecs_cluster_name

  # Namespace the Redis service registers in: either the one this module creates or an existing one
  service_discovery_namespace_id   = var.create_service_discovery_namespace ? aws_service_discovery_private_dns_namespace.redis[0].id : data.aws_service_discovery_dns_namespace.existing[0].id
  service_discovery_namespace_name = var.create_service_discovery_namespace ? aws_service_discovery_private_dns_namespace.redis[0].name : var.existing_service_discovery_namespace_name

  # Marks the client ingress rules the initializer owns, so it can find and revoke them
  redis_client_rule_description = "${var.cluster_name}-redis client access"

  cloudwatch_log_group_name = var.create_cloudwatch_log_group ? aws_cloudwatch_log_group.redis[0].name : var.existing_cloudwatch_log_group_name
}
