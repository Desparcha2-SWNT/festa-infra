# Entrada pública con HTTPS: API Gateway (HTTP API).
#
# El Learner Lab no permite CloudFront (AccessDenied) y no hay dominio propio para un certificado de ACM.
# API Gateway da una URL https://<id>.execute-api.<región>.amazonaws.com con certificado de AWS, así que la
# app (Android bloquea HTTP en las builds de release) habla HTTPS sin comprar un dominio.
#
# Camino: cliente ──HTTPS──► API Gateway ──VPC Link──► ALB interno ──► Kong ──► NLB interno ──► servicios.
#
# API Gateway escribe la IP del cliente en X-Real-IP (ver la integración). El VPC Link llega al ALB desde IPs de la
# VPC, en las que Kong confía (KONG_TRUSTED_IPS), así que el rate limit por IP de Kong ve al cliente real y no
# a API Gateway. Un X-Real-IP falso que mande el cliente se sobrescribe.
#
# Límite a tener en cuenta: API Gateway corta las peticiones a los 30 s. Hoy ningún servicio tarda tanto;
# ai-service (Sprint 3) tendrá que responder antes o usar streaming.

resource "aws_apigatewayv2_vpc_link" "gateway" {
  name               = local.name
  subnet_ids         = local.subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]
}

resource "aws_apigatewayv2_api" "main" {
  name          = local.name
  protocol_type = "HTTP"
  description   = "Entrada HTTPS de Festa (${var.env}) hacia Kong"
  # CORS lo resuelve Kong (plugin cors en festa-gateway); API Gateway deja pasar los OPTIONS.
}

resource "aws_apigatewayv2_integration" "gateway" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = aws_lb_listener.gateway_http.arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.gateway.id
  # El máximo que permite API Gateway.
  timeout_milliseconds = 30000

  # API Gateway no agrega la IP del cliente al reenviar por un VPC Link. Se escribe en X-Real-IP con
  # "overwrite", así un X-Real-IP que mande el cliente se reemplaza y no se puede falsificar.
  request_parameters = {
    "overwrite:header.X-Real-IP" = "$context.identity.sourceIp"
  }
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.gateway.id}"
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/apigw/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  # Límite global de la entrada, por encima de los de Kong: frena un abuso antes de que llegue a la VPC.
  default_route_settings {
    throttling_burst_limit = 200
    throttling_rate_limit  = 100
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      method    = "$context.httpMethod"
      path      = "$context.path"
      status    = "$context.status"
      latencyMs = "$context.responseLatency"
      error     = "$context.integrationErrorMessage"
    })
  }
}
