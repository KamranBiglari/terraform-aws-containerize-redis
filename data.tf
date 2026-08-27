# Current AWS region
data "aws_region" "current" {}

# Existing ECS cluster to deploy into when this module does not create one
data "aws_ecs_cluster" "existing" {
  count = var.create_ecs_cluster ? 0 : 1

  cluster_name = var.existing_ecs_cluster_name

  lifecycle {
    precondition {
      condition     = var.existing_ecs_cluster_name != null
      error_message = "existing_ecs_cluster_name must be set when create_ecs_cluster is false."
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
