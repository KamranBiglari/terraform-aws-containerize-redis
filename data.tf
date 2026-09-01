# Current AWS region, account and partition. Used to address resources this module
# does not create, without a lookup that could defer to apply.
data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Existing CloudMap namespace to register into when this module does not create one
data "aws_service_discovery_dns_namespace" "existing" {
  count = var.create_service_discovery_namespace ? 0 : 1

  name = var.existing_service_discovery_namespace_name
  type = var.existing_service_discovery_namespace_type

  lifecycle {
    precondition {
      condition     = var.existing_service_discovery_namespace_name != null
      error_message = "existing_service_discovery_namespace_name must be set when create_service_discovery_namespace is false."
    }
  }
}

# Archive Lambda function
data "archive_file" "lambda_zip" {
  count = var.enable_cluster_init ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/index.py"
  output_path = "${path.module}/lambda/redis_cluster_init.zip"
}

# Create Lambda Layer with redis-py
# Note: This requires running a build script first to install dependencies
# See lambda/build_layer.sh
data "archive_file" "lambda_layer" {
  count = var.enable_cluster_init ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/lambda/layer"
  output_path = "${path.module}/lambda/redis_layer.zip"

  depends_on = [null_resource.build_lambda_layer]
}
