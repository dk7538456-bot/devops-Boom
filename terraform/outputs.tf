output "application_url" { value = "http://${aws_lb.app.dns_name}" }
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }
output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "ecs_service_name" { value = aws_ecs_service.app.name }
output "github_deploy_role_arn" { value = var.github_repository == "" ? null : aws_iam_role.github_deploy[0].arn }
output "dynamodb_table_name" { value = aws_dynamodb_table.tasks.name }
