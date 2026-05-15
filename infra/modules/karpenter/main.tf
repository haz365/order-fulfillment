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

# ── IAM role for Karpenter controller ────────────────────────────────────────

resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer_host}:aud" = "sts.amazonaws.com"
          "${var.oidc_issuer_host}:sub" = "system:serviceaccount:karpenter:karpenter"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
        ]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}::image/*",
          "arn:aws:ec2:${data.aws_region.current.name}::snapshot/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:spot-instances-request/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:security-group/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:subnet/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:network-interface/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:volume/*",
        ]
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
        ]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:*:fleet/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:volume/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:network-interface/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:spot-instances-request/*",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
        ]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
          "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowRegionalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}::parameter/aws/service/*"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Action   = ["pricing:GetProducts"]
        Resource = "*"
      },
      {
        Sid    = "AllowInterruptionQueueActions"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid    = "AllowPassingInstanceRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = var.node_role_arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Action   = ["iam:CreateInstanceProfile"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileTagActions"
        Effect = "Allow"
        Action = ["iam:TagInstanceProfile"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"  = "owned"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileActions"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Action   = ["iam:GetInstanceProfile"]
        Resource = "*"
      },
      {
        Sid    = "AllowAPIServerEndpointDiscovery"
        Effect = "Allow"
        Action = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ── Karpenter interruption queue ──────────────────────────────────────────────

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = { Name = "${var.cluster_name}-karpenter" }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# ── EventBridge rules for spot interruption ───────────────────────────────────

resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  for_each    = {
    spot_interruption    = { source = ["aws.ec2"], type = "EC2 Spot Instance Interruption Warning" }
    rebalance            = { source = ["aws.ec2"], type = "EC2 Instance Rebalance Recommendation" }
    instance_state_change = { source = ["aws.ec2"], type = "EC2 Instance State-change Notification" }
  }

  name          = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode({
    source      = each.value.source
    detail-type = [each.value.type]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  for_each  = aws_cloudwatch_event_rule.karpenter_interruption
  rule      = each.value.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ── Instance profile for Karpenter nodes ─────────────────────────────────────

resource "aws_iam_instance_profile" "karpenter" {
  name = "KarpenterNodeInstanceProfile-${var.cluster_name}"
  role = split("/", var.node_role_arn)[1]
}