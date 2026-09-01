# ECS Cluster
resource "aws_ecs_cluster" "redis_cluster" {
  count = var.create_ecs_cluster ? 1 : 0
  name  = coalesce(var.ecs_cluster_name, "${var.cluster_name}-redis")

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = var.tags
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "redis" {
  count             = var.create_cloudwatch_log_group ? 1 : 0
  name              = coalesce(var.cloudwatch_log_group_name, "/ecs/${var.cluster_name}-redis")
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# Redis password
#
# Generated unless one is supplied. The generated value avoids quotes and
# backslashes: the password reaches redis-server through a shell command line.
resource "random_password" "redis" {
  count = var.create_redis_password_secret && var.redis_password == null ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#%&*+-.:=?@_~"
}

resource "aws_secretsmanager_secret" "redis_password" {
  count = var.create_redis_password_secret ? 1 : 0

  name        = coalesce(var.redis_password_secret_name, "${var.cluster_name}-redis-password")
  description = "Redis AUTH password for ${var.cluster_name}"

  tags = var.tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.existing_redis_password_secret_arn == null
      error_message = "Set either create_redis_password_secret or existing_redis_password_secret_arn, not both."
    }
  }
}

resource "aws_secretsmanager_secret_version" "redis_password" {
  count = var.create_redis_password_secret ? 1 : 0

  secret_id = aws_secretsmanager_secret.redis_password[0].id

  # A connection document, so consumers get everything they need from one secret
  secret_string = jsonencode({
    host     = local.redis_endpoint
    port     = local.redis_port
    password = coalesce(var.redis_password, try(random_password.redis[0].result, null))
    type     = "redis-cluster"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Security Group for Redis Cluster
#
# Rules are standalone resources rather than inline blocks: inline rules are
# authoritative and would fight the client rules, which have to be created
# after cluster initialization rather than alongside the group.
resource "aws_security_group" "redis_cluster" {
  name_prefix = "${var.cluster_name}-redis-"
  description = "Security group for Redis cluster"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-redis-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Node-to-node traffic. The init Lambda shares this security group, so this also
# covers the Lambda reaching the nodes while clients are still locked out.
resource "aws_vpc_security_group_ingress_rule" "redis_node" {
  security_group_id = aws_security_group.redis_cluster.id
  description       = "Redis port from cluster members"

  referenced_security_group_id = aws_security_group.redis_cluster.id
  from_port                    = local.redis_port
  to_port                      = local.redis_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "redis_bus" {
  security_group_id = aws_security_group.redis_cluster.id
  description       = "Redis cluster bus port from cluster members"

  referenced_security_group_id = aws_security_group.redis_cluster.id
  from_port                    = local.redis_cluster_port
  to_port                      = local.redis_cluster_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

# Client access.
#
# When cluster initialization is enabled these rules are managed by the init
# Lambda, not by Terraform: it revokes them before it forms the cluster and
# re-authorizes them once the cluster is healthy, on every deployment. Nodes come
# up as standalone empty instances and Redis refuses to cluster nodes that
# already hold keys, so clients must stay out until initialization finishes.
#
# With initialization disabled there is nothing to wait for, so Terraform manages
# them directly.
resource "aws_vpc_security_group_ingress_rule" "redis_client" {
  for_each = var.enable_cluster_init ? toset([]) : toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.redis_cluster.id
  description       = local.redis_client_rule_description

  cidr_ipv4   = each.value
  from_port   = local.redis_port
  to_port     = local.redis_port
  ip_protocol = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "redis_all" {
  security_group_id = aws_security_group.redis_cluster.id
  description       = "Allow all outbound"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  tags = var.tags
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

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Lets ECS inject the Redis password into the container at task start
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  count = local.redis_auth_enabled ? 1 : 0

  name_prefix = "redis-secret-"
  role        = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.redis_password_secret_arn
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }
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

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
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
  count = var.create_service_discovery_namespace ? 1 : 0

  name        = var.service_discovery_namespace
  description = "Private DNS namespace for Redis cluster"
  vpc         = var.vpc_id

  tags = var.tags
}

# CloudMap Service for Redis Cluster
resource "aws_service_discovery_service" "redis" {
  name = var.service_discovery_name

  dns_config {
    namespace_id = local.service_discovery_namespace_id

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

      # Without auth the server is exec'd directly. With auth the password only
      # exists as an environment variable injected from Secrets Manager, and ECS
      # does not expand variables in command arguments, so it goes through a shell.
      entryPoint = local.redis_auth_enabled ? ["/bin/sh", "-c"] : null

      command = local.redis_auth_enabled ? [join(" ", concat(
        ["exec redis-server"],
        local.redis_server_args,
        # masterauth lets replicas authenticate to their master
        ["--requirepass \"$REDIS_PASSWORD\"", "--masterauth \"$REDIS_PASSWORD\""],
      ))] : concat(["redis-server"], local.redis_server_args)

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.cloudwatch_log_group_name
          "awslogs-region"        = local.aws_region
          "awslogs-stream-prefix" = "redis"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", local.redis_health_check_command]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      secrets = local.redis_auth_enabled ? [
        {
          name      = "REDIS_PASSWORD"
          valueFrom = local.redis_password_value_from
        }
      ] : []

      environment = concat([
        {
          name  = "REDIS_PORT"
          value = tostring(local.redis_port)
        },
        {
          name  = "REDIS_CLUSTER_PORT"
          value = tostring(local.redis_cluster_port)
        }
      ], var.redis_environment_variables)
    }
  ])

  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.redis_port != local.redis_cluster_port
      error_message = "redis_port and redis_cluster_port must be different ports."
    }

    precondition {
      condition     = local.redis_cluster_port > 0 && local.redis_cluster_port < 65536
      error_message = "The Redis cluster bus port must be between 1 and 65535; set redis_cluster_port explicitly when redis_port + 10000 exceeds the port range."
    }
  }
}

# Deleting the ECS service returns before CloudMap has finished deregistering the
# task instances, and CloudMap refuses to delete a service that still has any
# ("ResourceInUse: Service contains registered instances"). This sits between the
# two in the dependency chain, so destroying waits after the ECS service is gone
# and before the service discovery service is deleted.
resource "time_sleep" "service_discovery_deregistration" {
  depends_on = [aws_service_discovery_service.redis]

  destroy_duration = var.service_discovery_deregistration_delay
}

# ECS Service for Redis Cluster
resource "aws_ecs_service" "redis_cluster" {
  name            = "${var.cluster_name}-redis-service"
  cluster         = local.ecs_cluster_arn
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

  propagate_tags = "SERVICE"

  lifecycle {
    precondition {
      condition     = var.create_ecs_cluster || var.existing_ecs_cluster_name != null
      error_message = "existing_ecs_cluster_name must be set when create_ecs_cluster is false."
    }

    precondition {
      condition     = var.create_cloudwatch_log_group || var.existing_cloudwatch_log_group_name != null
      error_message = "existing_cloudwatch_log_group_name must be set when create_cloudwatch_log_group is false."
    }
  }

  # Enable ECS Exec if needed for debugging or Lambda-based cluster initialization
  enable_execute_command = var.enable_ecs_exec || var.enable_cluster_init

  tags = merge(var.tags, {
    (var.ecs_service_config_tags["desired_count"]) = tostring(local.total_nodes)
  })

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy,
    time_sleep.service_discovery_deregistration,
  ]
}

# Lambda Layer with redis-py dependency
resource "aws_lambda_layer_version" "redis_layer" {
  count = var.enable_cluster_init ? 1 : 0

  filename            = "${path.module}/lambda/redis_layer.zip"
  layer_name          = "${var.cluster_name}-redis-layer"
  compatible_runtimes = ["python3.11", "python3.10", "python3.9"]
  source_code_hash    = data.archive_file.lambda_layer[0].output_base64sha256

  description = "Redis Python library for cluster initialization"

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
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
  timeout          = var.cluster_init_timeout

  # Steady-state events can arrive in bursts (a deployment plus a scale change).
  # One concurrent execution keeps two runs from racing through CLUSTER MEET;
  # Lambda retries the throttled invocation.
  reserved_concurrent_executions = 1
  layers                         = [aws_lambda_layer_version.redis_layer[0].arn]

  environment {
    variables = {
      ECS_CLUSTER_ARN           = local.ecs_cluster_arn
      ECS_SERVICE_NAME          = aws_ecs_service.redis_cluster.name
      REDIS_MASTER_COUNT        = var.redis_master_count
      REDIS_REPLICA_COUNT       = var.redis_replica_count
      CLOUDMAP_NAMESPACE        = local.service_discovery_namespace_name
      CLOUDMAP_SERVICE          = aws_service_discovery_service.redis.name
      VPC_ID                    = var.vpc_id
      SUBNET_IDS                = join(",", var.subnet_ids)
      SECURITY_GROUP_ID         = aws_security_group.redis_cluster.id
      ALLOWED_CIDR_BLOCKS       = join(",", var.allowed_cidr_blocks)
      CLIENT_RULE_DESC          = local.redis_client_rule_description
      REDIS_PASSWORD_SECRET_ARN = local.redis_auth_enabled ? local.redis_password_secret_arn : ""
      REDIS_PASSWORD_SECRET_KEY = var.create_redis_password_secret ? local.redis_password_secret_json_key : (var.existing_redis_password_secret_key == null ? "" : var.existing_redis_password_secret_key)
      REDIS_PORT                = tostring(local.redis_port)
      REDIS_CLUSTER_PORT        = tostring(local.redis_cluster_port)
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.redis_cluster.id]
  }

  tags = var.tags

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
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

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_execution" {
  count = var.enable_cluster_init ? 1 : 0

  role       = aws_iam_role.lambda_exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
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
          "ecs:DescribeServices",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:DescribeTaskDefinition",
          "ecs:ExecuteCommand"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "servicediscovery:DiscoverInstances",
          "servicediscovery:GetNamespace",
          "servicediscovery:GetService"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSecurityGroupRules"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = aws_security_group.redis_cluster.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.redis_auth_enabled ? local.redis_password_secret_arn : "arn:aws:secretsmanager:*:*:secret:__none__"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
          "ssm:SendCommand"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
}

# Build the Lambda layer with dependencies
resource "null_resource" "build_lambda_layer" {
  count = var.enable_cluster_init ? 1 : 0

  triggers = {
    requirements = filemd5("${path.module}/lambda/requirements.txt")
    build_script = filemd5("${path.module}/lambda/build_layer.sh")
    build_method = var.lambda_layer_build_method
    build_image  = var.lambda_layer_build_image

    # The built layer is not part of the module source, so a module directory that
    # was just downloaded (a new machine, a CI runner, a cleaned .terraform) has no
    # lambda/layer to archive. Rebuild whenever it is missing instead of trusting
    # that a previous apply on some other machine produced it.
    #
    # The timestamp matters: triggers record the value seen at plan time, which is
    # always "missing" on a run that builds the layer. A constant would therefore
    # match on the next machine that is also missing it, leaving this resource
    # unchanged - and an unchanged dependency lets Terraform read the archive at
    # plan time, before the build has run. A value that differs on every plan keeps
    # the rebuild (and the archive's deferral to apply) guaranteed while the layer
    # is absent, and goes quiet once it is present.
    layer_present = length(fileset("${path.module}/lambda", "layer/python/redis/__init__.py")) > 0 ? "present" : timestamp()
  }

  provisioner "local-exec" {
    interpreter = var.lambda_layer_build_interpreter

    # Invoked through bash rather than executed directly: the script's mode bit
    # does not survive every checkout (Windows clones, archive downloads, module
    # sources that unpack without permissions), and a non-executable file fails
    # with a bare "Permission denied".
    command     = "bash ./lambda/build_layer.sh"
    working_dir = path.module

    environment = {
      LAYER_BUILD_METHOD = var.lambda_layer_build_method
      LAYER_BUILD_IMAGE  = var.lambda_layer_build_image
    }
  }
}

# Re-initialize whenever the service reaches steady state again - a restart, a
# scale change, or a new task definition all replace the Redis nodes. The Lambda
# is a no-op when it finds a healthy cluster already in place.
resource "aws_cloudwatch_event_rule" "ecs_service_stable" {
  count = var.enable_cluster_init ? 1 : 0

  name_prefix = "${var.cluster_name}-redis-stable-"
  description = "Trigger cluster initialization when the Redis service becomes stable"

  # Matched on the service ARN in `resources`, not on the cluster: a cluster can
  # host many services and every one of them emits these events.
  #
  # Two events are matched because either can be missed on its own. Deployment
  # events carry no clusterArn, which is why the cluster is not part of the
  # pattern - including it would stop them from ever matching.
  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Service Action", "ECS Deployment State Change"]
    resources   = [aws_ecs_service.redis_cluster.id]
    detail = {
      eventName = ["SERVICE_STEADY_STATE", "SERVICE_DEPLOYMENT_COMPLETED"]
    }
  })

  tags = var.tags

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_event_target" "lambda" {
  count = var.enable_cluster_init ? 1 : 0

  rule      = aws_cloudwatch_event_rule.ecs_service_stable[0].name
  target_id = "RedisClusterInit"
  arn       = aws_lambda_function.redis_cluster_init[0].arn

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lambda_permission" "allow_cloudwatch" {
  count = var.enable_cluster_init ? 1 : 0

  statement_id_prefix = "AllowExecutionFromCloudWatch"
  action              = "lambda:InvokeFunction"
  function_name       = aws_lambda_function.redis_cluster_init[0].function_name
  principal           = "events.amazonaws.com"
  source_arn          = aws_cloudwatch_event_rule.ecs_service_stable[0].arn

  # Replaced together with the rest of this chain whenever cluster_name changes.
  # Every resource in the chain has to agree on the ordering, otherwise Terraform
  # cannot sequence the swap and reports a dependency cycle.
  lifecycle {
    create_before_destroy = true
  }
}
