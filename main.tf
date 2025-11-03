locals {
  redis_port         = 6379
  redis_cluster_port = 16379
  total_nodes        = var.redis_master_count + var.redis_replica_count
  redis_nodes        = [for i in range(local.total_nodes) : "redis-node-${i}"]
  aws_region         = var.aws_region != null ? var.aws_region : data.aws_region.current.name
}

# ECS Cluster
resource "aws_ecs_cluster" "redis_cluster" {
  name = "${var.cluster_name}-redis"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = var.tags
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "redis" {
  name              = "/ecs/${var.cluster_name}-redis"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# Security Group for Redis Cluster
resource "aws_security_group" "redis_cluster" {
  name_prefix = "${var.cluster_name}-redis-"
  description = "Security group for Redis cluster"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis port"
    from_port   = local.redis_port
    to_port     = local.redis_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    self        = true
  }

  ingress {
    description = "Redis cluster bus port"
    from_port   = local.redis_cluster_port
    to_port     = local.redis_cluster_port
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-redis-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name_prefix = "${var.cluster_name}-redis-exec-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IAM Role for ECS Task
resource "aws_iam_role" "ecs_task_role" {
  name_prefix = "${var.cluster_name}-redis-task-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# Allow ECS tasks to discover services in CloudMap
resource "aws_iam_role_policy" "ecs_task_cloudmap_policy" {
  name_prefix = "cloudmap-discovery-"
  role        = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "servicediscovery:DiscoverInstances",
          "servicediscovery:ListNamespaces",
          "servicediscovery:ListServices",
          "servicediscovery:ListInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:ListTasks",
          "ecs:DescribeTasks"
        ]
        Resource = "*"
      }
    ]
  })
}

# CloudMap Private DNS Namespace
resource "aws_service_discovery_private_dns_namespace" "redis" {
  name        = var.service_discovery_namespace
  description = "Private DNS namespace for Redis cluster"
  vpc         = var.vpc_id

  tags = var.tags
}

# CloudMap Service for Redis Cluster
resource "aws_service_discovery_service" "redis" {
  name = "redis-cluster"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.redis.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = var.tags
}

# ECS Task Definition for Redis Nodes
resource "aws_ecs_task_definition" "redis_node" {
  family                   = "${var.cluster_name}-redis-node"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "redis"
      image     = var.redis_image
      essential = true

      portMappings = [
        {
          containerPort = local.redis_port
          protocol      = "tcp"
        },
        {
          containerPort = local.redis_cluster_port
          protocol      = "tcp"
        }
      ]

      command = [
        "redis-server",
        "--cluster-enabled", "yes",
        "--cluster-config-file", "nodes.conf",
        "--cluster-node-timeout", "5000",
        "--appendonly", "yes",
        "--protected-mode", "no",
        "--bind", "0.0.0.0",
        "--port", tostring(local.redis_port),
        "--cluster-announce-port", tostring(local.redis_port),
        "--cluster-announce-bus-port", tostring(local.redis_cluster_port)
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.redis.name
          "awslogs-region"        = local.aws_region
          "awslogs-stream-prefix" = "redis"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "redis-cli ping | grep PONG"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      environment = var.redis_environment_variables
    }
  ])

  tags = var.tags
}

# ECS Service for Redis Cluster
resource "aws_ecs_service" "redis_cluster" {
  name            = "${var.cluster_name}-redis-service"
  cluster         = aws_ecs_cluster.redis_cluster.id
  task_definition = aws_ecs_task_definition.redis_node.arn
  desired_count   = local.total_nodes
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.redis_cluster.id]
    assign_public_ip = var.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.redis.arn
  }

  # Deployment configuration for rolling updates
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Enable ECS Exec if needed for debugging
  enable_execute_command = var.enable_ecs_exec

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy
  ]
}

# Lambda function to initialize Redis cluster
resource "aws_lambda_function" "redis_cluster_init" {
  count = var.enable_cluster_init ? 1 : 0

  filename         = "${path.module}/lambda/redis_cluster_init.zip"
  function_name    = "${var.cluster_name}-redis-cluster-init"
  role             = aws_iam_role.lambda_exec[0].arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.lambda_zip[0].output_base64sha256
  runtime          = "python3.11"
  timeout          = 300

  environment {
    variables = {
      ECS_CLUSTER_ARN     = aws_ecs_cluster.redis_cluster.arn
      ECS_SERVICE_NAME    = aws_ecs_service.redis_cluster.name
      REDIS_MASTER_COUNT  = var.redis_master_count
      REDIS_REPLICA_COUNT = var.redis_replica_count
      CLOUDMAP_NAMESPACE  = var.service_discovery_namespace
      CLOUDMAP_SERVICE    = aws_service_discovery_service.redis.name
      VPC_ID              = var.vpc_id
      SUBNET_IDS          = join(",", var.subnet_ids)
      SECURITY_GROUP_ID   = aws_security_group.redis_cluster.id
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.redis_cluster.id]
  }

  tags = var.tags
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec" {
  count = var.enable_cluster_init ? 1 : 0

  name_prefix = "${var.cluster_name}-redis-lambda-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_execution" {
  count = var.enable_cluster_init ? 1 : 0

  role       = aws_iam_role.lambda_exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_ecs_policy" {
  count = var.enable_cluster_init ? 1 : 0

  name_prefix = "ecs-access-"
  role        = aws_iam_role.lambda_exec[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:ExecuteCommand"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "servicediscovery:DiscoverInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

# Archive Lambda function
data "archive_file" "lambda_zip" {
  count = var.enable_cluster_init ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/index.py"
  output_path = "${path.module}/lambda/redis_cluster_init.zip"
}

# CloudWatch Event Rule to trigger Lambda after service stabilizes
resource "aws_cloudwatch_event_rule" "ecs_service_stable" {
  count = var.enable_cluster_init ? 1 : 0

  name_prefix = "${var.cluster_name}-redis-stable-"
  description = "Trigger when ECS service becomes stable"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Service Action"]
    detail = {
      eventName  = ["SERVICE_STEADY_STATE"]
      clusterArn = [aws_ecs_cluster.redis_cluster.arn]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "lambda" {
  count = var.enable_cluster_init ? 1 : 0

  rule      = aws_cloudwatch_event_rule.ecs_service_stable[0].name
  target_id = "RedisClusterInit"
  arn       = aws_lambda_function.redis_cluster_init[0].arn
}

resource "aws_lambda_permission" "allow_cloudwatch" {
  count = var.enable_cluster_init ? 1 : 0

  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.redis_cluster_init[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecs_service_stable[0].arn
}
