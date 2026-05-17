terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Helper locals ─────────────────────────────────────────────────────────────

locals {
  oidc = var.oidc_issuer_host
}

# ── Generic IRSA role factory ─────────────────────────────────────────────────

resource "aws_iam_role" "external_dns" {
  name = "${var.cluster_name}-external-dns"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc}:aud" = "sts.amazonaws.com"
          "${local.oidc}:sub" = "system:serviceaccount:external-dns:external-dns"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "external_dns" {
  name = "${var.cluster_name}-external-dns"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource",
        ]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns.arn
}

# ── CertManager ───────────────────────────────────────────────────────────────

resource "aws_iam_role" "cert_manager" {
  name = "${var.cluster_name}-cert-manager"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc}:aud" = "sts.amazonaws.com"
          "${local.oidc}:sub" = "system:serviceaccount:cert-manager:cert-manager"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "cert_manager" {
  name = "${var.cluster_name}-cert-manager"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = ["arn:aws:route53:::change/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = ["arn:aws:route53:::hostedzone/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cert_manager" {
  role       = aws_iam_role.cert_manager.name
  policy_arn = aws_iam_policy.cert_manager.arn
}

# ── Order service ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "order_service" {
  name = "${var.cluster_name}-order-service"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc}:aud" = "sts.amazonaws.com"
          "${local.oidc}:sub" = "system:serviceaccount:order-fulfillment:order-service"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "order_service" {
  name = "${var.cluster_name}-order-service"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [var.sqs_queue_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "order_service" {
  role       = aws_iam_role.order_service.name
  policy_arn = aws_iam_policy.order_service.arn
}

# ── Payment service ───────────────────────────────────────────────────────────

resource "aws_iam_role" "payment_service" {
  name = "${var.cluster_name}-payment-service"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc}:aud" = "sts.amazonaws.com"
          "${local.oidc}:sub" = "system:serviceaccount:order-fulfillment:payment-service"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "payment_service" {
  name = "${var.cluster_name}-payment-service"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [var.sqs_queue_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "payment_service" {
  role       = aws_iam_role.payment_service.name
  policy_arn = aws_iam_policy.payment_service.arn
}

# ── Shipping service ──────────────────────────────────────────────────────────

resource "aws_iam_role" "shipping_service" {
  name = "${var.cluster_name}-shipping-service"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc}:aud" = "sts.amazonaws.com"
          "${local.oidc}:sub" = "system:serviceaccount:order-fulfillment:shipping-service"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "shipping_service" {
  name = "${var.cluster_name}-shipping-service"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [var.sqs_queue_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "shipping_service" {
  role       = aws_iam_role.shipping_service.name
  policy_arn = aws_iam_policy.shipping_service.arn
}

# ── Worker ────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "worker" {
  name = "${var.cluster_name}-worker"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc}:aud" = "sts.amazonaws.com"
          "${local.oidc}:sub" = "system:serviceaccount:order-fulfillment:worker"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "worker" {
  name = "${var.cluster_name}-worker"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      Resource = [var.sqs_queue_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "worker" {
  role       = aws_iam_role.worker.name
  policy_arn = aws_iam_policy.worker.arn
}

# ── Notification service ──────────────────────────────────────────────────────

resource "aws_iam_role" "notification_service" {
  name = "${var.cluster_name}-notification-service"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc}:aud" = "sts.amazonaws.com"
          "${local.oidc}:sub" = "system:serviceaccount:order-fulfillment:notification-service"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "notification_service" {
  name = "${var.cluster_name}-notification-service"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      Resource = [var.sqs_queue_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "notification_service" {
  role       = aws_iam_role.notification_service.name
  policy_arn = aws_iam_policy.notification_service.arn
}

# ── Scheduler ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "scheduler" {
  name = "${var.cluster_name}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc}:aud" = "sts.amazonaws.com"
          "${local.oidc}:sub" = "system:serviceaccount:order-fulfillment:scheduler"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "scheduler" {
  name = "${var.cluster_name}-scheduler"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [var.sqs_queue_arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "scheduler" {
  role       = aws_iam_role.scheduler.name
  policy_arn = aws_iam_policy.scheduler.arn
}

# ── GitHub Actions OIDC ───────────────────────────────────────────────────────

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions" {
  name = "${var.cluster_name}-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:haz365/order-fulfillment:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  role = aws_iam_role.github_actions.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECR"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:ListImages",
          "ecr:DescribeRepositories",
        ]
        Resource = "*"
      },
      {
        Sid    = "EKS"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
        ]
        Resource = "*"
      },
      {
        Sid    = "S3State"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::order-fulfillment-tfstate-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::order-fulfillment-tfstate-${data.aws_caller_identity.current.account_id}/*",
        ]
      },
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:eu-west-2:${data.aws_caller_identity.current.account_id}:table/order-fulfillment-tfstate-lock"
      },
      {
        Sid    = "KMS"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
      }
    ]
  })
}