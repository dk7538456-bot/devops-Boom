data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name = var.project_name
  common_tags = { Project = local.name, ManagedBy = "Terraform" }
}

resource "aws_vpc" "main" {
  cidr_block = "10.42.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
  tags = merge(local.common_tags, { Name = "${local.name}-vpc" })
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = merge(local.common_tags, { Name = "${local.name}-igw" })
}
resource "aws_subnet" "public" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 1)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = merge(local.common_tags, { Name = "${local.name}-public-${count.index + 1}" })
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.common_tags, { Name = "${local.name}-public" })
}
resource "aws_route_table_association" "public" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_dynamodb_table" "tasks" {
  name = "${local.name}-tasks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key = "task_id"
  attribute {
    name = "task_id"
    type = "S"
  }
  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }
  tags = local.common_tags
}
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [aws_route_table.public.id]
  tags = local.common_tags
}

resource "aws_ecr_repository" "app" {
  name = local.name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  tags = local.common_tags
}
resource "aws_cloudwatch_log_group" "app" {
  name = "/ecs/${local.name}"
  retention_in_days = 14
  tags = local.common_tags
}

resource "aws_iam_role" "execution" {
  name = "${local.name}-execution"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags = local.common_tags
}
resource "aws_iam_role_policy_attachment" "execution" {
  role = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name = "${local.name}-task"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags = local.common_tags
}
resource "aws_iam_role_policy" "dynamodb" {
  name = "${local.name}-tasks-table"
  role = aws_iam_role.task.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Scan"], Resource = aws_dynamodb_table.tasks.arn }] })
}

resource "aws_security_group" "alb" {
  name = "${local.name}-alb"
  description = "Public HTTP ingress for the application load balancer"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.common_tags
}
resource "aws_security_group" "app" {
  name = "${local.name}-app"
  description = "Only the load balancer can reach the application tasks"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = var.container_port
    to_port = var.container_port
    protocol = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.common_tags
}
resource "aws_lb" "app" {
  name = "${local.name}-alb"
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.alb.id]
  subnets = aws_subnet.public[*].id
  tags = local.common_tags
}
resource "aws_lb_target_group" "app" {
  name = "${local.name}-targets"
  port = var.container_port
  protocol = "HTTP"
  vpc_id = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/health/live"
    matcher = "200"
    interval = 30
    healthy_threshold = 2
    unhealthy_threshold = 3
  }
  tags = local.common_tags
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port = 80
  protocol = "HTTP"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name = "containerInsights"
    value = "enabled"
  }
  tags = local.common_tags
}
resource "aws_ecs_task_definition" "app" {
  family = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode = "awsvpc"
  cpu = var.cpu
  memory = var.memory
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name = local.name, image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}", essential = true
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment = [{ name = "AWS_REGION", value = var.aws_region }, { name = "TASKS_TABLE", value = aws_dynamodb_table.tasks.name }, { name = "APP_VERSION", value = var.image_tag }]
    logConfiguration = { logDriver = "awslogs", options = { "awslogs-group" = aws_cloudwatch_log_group.app.name, "awslogs-region" = var.aws_region, "awslogs-stream-prefix" = "app" } }
    healthCheck = { command = ["CMD-SHELL", "python -c \"from urllib.request import urlopen; urlopen('http://127.0.0.1:8000/health/live', timeout=3)\" || exit 1"], interval = 30, timeout = 5, retries = 3, startPeriod = 10 }
  }])
  tags = local.common_tags
}
resource "aws_ecs_service" "app" {
  name = local.name
  cluster = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count = var.desired_count
  launch_type = "FARGATE"
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent = 200
  health_check_grace_period_seconds = 60
  network_configuration {
    subnets = aws_subnet.public[*].id
    security_groups = [aws_security_group.app.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name = local.name
    container_port = var.container_port
  }
  depends_on = [aws_lb_listener.http, aws_iam_role_policy_attachment.execution, aws_iam_role_policy.dynamodb]
  tags = local.common_tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.github_repository == "" ? 0 : 1
  url = "https://token.actions.githubusercontent.com"
}
resource "aws_iam_role" "github_deploy" {
  count = var.github_repository == "" ? 0 : 1
  name = "${local.name}-github-deploy"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = data.aws_iam_openid_connect_provider.github[0].arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com", "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/main" } } }] })
  tags = local.common_tags
}
resource "aws_iam_role_policy" "github_deploy" {
  count = var.github_repository == "" ? 0 : 1
  name = "${local.name}-github-deploy"
  role = aws_iam_role.github_deploy[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"], Resource = aws_ecr_repository.app.arn },
    { Effect = "Allow", Action = ["ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:UpdateService", "ecs:RegisterTaskDefinition"], Resource = [aws_ecs_cluster.main.arn, aws_ecs_service.app.id, "*"] },
    { Effect = "Allow", Action = ["iam:PassRole"], Resource = [aws_iam_role.execution.arn, aws_iam_role.task.arn] }
  ] })
}
