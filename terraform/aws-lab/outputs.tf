output "api_base_url" {
  description = "URL pública (HTTPS) de la API. Es la API_BASE_URL de festa-mobile."
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "internal_nlb" {
  description = "DNS del balanceador interno (servicios y RabbitMQ)."
  value       = aws_lb.internal.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "secret_arn" {
  description = "Secreto con las llaves y contraseñas del entorno (ADMIN_PASSWORD incluido)."
  value       = aws_secretsmanager_secret.app.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.main.name
}
