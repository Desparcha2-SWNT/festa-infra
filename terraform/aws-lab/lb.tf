# Balanceadores.
# - ALB interno: delante de Kong (festa-gateway). Desde internet solo se llega por API Gateway (apigw.tf),
#   que termina HTTPS y entra a la VPC por un VPC Link. El ALB no tiene IP pública.
# - NLB interno: reemplaza el DNS por nombre de servicio, porque el Learner Lab no permite Cloud Map. Cada
#   servicio tiene un puerto (8081 auth … 8088 analytics), RabbitMQ el 5672 y MongoDB el 27017. Kong recibe estas URLs
#   por variables de entorno (festa-gateway#5). Es NLB y no ALB porque AMQP es TCP, no HTTP.

resource "aws_lb" "gateway" {
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  internal                   = true
  security_groups            = [aws_security_group.alb.id]
  subnets                    = local.subnet_ids
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "gateway" {
  name                 = "${local.name}-gateway"
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 15

  # El status de Kong vive en otro puerto (8100) y no se expone al público.
  health_check {
    path                = "/status"
    port                = "8100"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Excepción revisada: el HTTPS del cliente termina en API Gateway, con certificado de AWS. Este listener
# solo recibe tráfico del VPC Link, dentro de la VPC, como el NLB interno. Un certificado propio necesitaría
# un dominio, y el Learner Lab no permite CloudFront.
#trivy:ignore:AVD-AWS-0054
resource "aws_lb_listener" "gateway_http" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

resource "aws_lb" "internal" {
  name               = "${local.name}-internal"
  load_balancer_type = "network"
  internal           = true
  subnets            = local.subnet_ids
  # Un servicio que llama a otro puede caer en otra zona: sin esto, el NLB solo usa destinos de su zona.
  enable_cross_zone_load_balancing = true
}

locals {
  # Puertos del NLB interno. Mismos números que en el compose.
  internal_ports = {
    auth         = { port = 8081, health = "/health" }
    user         = { port = 8082, health = "/health" }
    event        = { port = 8083, health = "/health" }
    booking      = { port = 8084, health = "/health" }
    payment      = { port = 8085, health = "/health" }
    ai           = { port = 8086, health = "/health" }
    notification = { port = 8087, health = "/health" }
    analytics    = { port = 8088, health = "/health" }
    rabbitmq     = { port = 5672, health = null }
    mongo        = { port = 27017, health = null }
  }

  # Gateway y microservicios: las imágenes que publica el CD de cada repo en GHCR.
  app_names = ["auth", "user", "event", "booking", "payment", "ai", "notification", "analytics", "gateway"]
}

resource "aws_lb_target_group" "internal" {
  for_each = local.internal_ports

  name                 = "${local.name}-${each.key}"
  port                 = each.value.port
  protocol             = "TCP"
  target_type          = "ip"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 15

  health_check {
    protocol            = each.value.health == null ? "TCP" : "HTTP"
    path                = each.value.health
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "internal" {
  for_each = local.internal_ports

  load_balancer_arn = aws_lb.internal.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.internal[each.key].arn
  }
}

locals {
  internal_url = { for k, v in local.internal_ports : k => "http://${aws_lb.internal.dns_name}:${v.port}" if !contains(["rabbitmq", "mongo"], k) }
}
