output "controller_role_arn"     { value = aws_iam_role.karpenter_controller.arn }
output "interruption_queue_name" { value = aws_sqs_queue.karpenter_interruption.name }
output "interruption_queue_arn"  { value = aws_sqs_queue.karpenter_interruption.arn }
output "instance_profile_name"   { value = aws_iam_instance_profile.karpenter.name }