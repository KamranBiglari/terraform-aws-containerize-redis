# Current AWS region
data "aws_region" "current" {}

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
