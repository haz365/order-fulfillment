terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
  default_tags {
    tags = {
      Project     = "order-fulfillment"
      Environment = "dev"
      ManagedBy   = "terraform"
      StateLayer  = "addons"
    }
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket         = "order-fulfillment-tfstate-989346120260"
    key            = "network/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "order-fulfillment-tfstate-lock"
  }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket         = "order-fulfillment-tfstate-989346120260"
    key            = "cluster/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "order-fulfillment-tfstate-lock"
  }
}

# ── SQS queues ────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "orders_dlq" {
  name                      = "order-fulfillment-dev-orders-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = { Name = "order-fulfillment-dev-orders-dlq" }
}

resource "aws_sqs_queue" "orders" {
  name                       = "order-fulfillment-dev-orders"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = 5
  })

  tags = { Name = "order-fulfillment-dev-orders" }
}

# ── CloudWatch alarms ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "order-fulfillment-dev-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "DLQ has messages"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.orders_dlq.name
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq_age" {
  alarm_name          = "order-fulfillment-dev-dlq-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 3600
  alarm_description   = "DLQ message age exceeds 1 hour"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.orders_dlq.name
  }
}

# ── Karpenter ─────────────────────────────────────────────────────────────────

module "karpenter" {
  source            = "../../modules/karpenter"
  project           = "order-fulfillment"
  environment       = "dev"
  cluster_name      = data.terraform_remote_state.cluster.outputs.cluster_name
  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
  oidc_issuer_host  = data.terraform_remote_state.cluster.outputs.oidc_issuer_host
  node_role_arn     = data.terraform_remote_state.cluster.outputs.node_role_arn
}

# ── IRSA ──────────────────────────────────────────────────────────────────────

module "irsa" {
  source            = "../../modules/irsa"
  project           = "order-fulfillment"
  environment       = "dev"
  cluster_name      = data.terraform_remote_state.cluster.outputs.cluster_name
  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
  oidc_issuer_host  = data.terraform_remote_state.cluster.outputs.oidc_issuer_host
  sqs_queue_arn     = aws_sqs_queue.orders.arn
  sqs_queue_url     = aws_sqs_queue.orders.url
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "sqs_queue_url"              { value = aws_sqs_queue.orders.url }
output "sqs_queue_arn"              { value = aws_sqs_queue.orders.arn }
output "sqs_dlq_url"                { value = aws_sqs_queue.orders_dlq.url }
output "karpenter_controller_role"  { value = module.karpenter.controller_role_arn }
output "karpenter_queue_name"       { value = module.karpenter.interruption_queue_name }
output "karpenter_instance_profile" { value = module.karpenter.instance_profile_name }
output "irsa"                       { value = module.irsa }
output "github_actions_role_arn"    { value = module.irsa.github_actions_role_arn }