# Red: la VPC por defecto del Learner Lab. Sus subredes son públicas, así que las tareas de Fargate salen a
# internet (a GHCR, a Docker Hub vía ECR Public) con IP pública y no hace falta un NAT Gateway, que es de lo
# más caro en una cuenta pequeña. Lo que protege a las tareas son los security groups: nada entra desde
# internet salvo al balanceador público.
data "aws_vpc" "default" {
  default = true
}

# Dos zonas: el ALB y los grupos de subredes de RDS y ElastiCache piden al menos dos.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["${var.region}a", "${var.region}b"]
  }
}

locals {
  name       = "festa-${var.env}"
  subnet_ids = sort(data.aws_subnets.default.ids)
  vpc_cidr   = data.aws_vpc.default.cidr_block
}

# Interfaces del VPC Link de API Gateway: solo hablan con el ALB interno.
resource "aws_security_group" "vpc_link" {
  name        = "${local.name}-vpc-link"
  description = "VPC Link de API Gateway hacia el ALB interno"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Hacia el ALB interno"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }
}

resource "aws_security_group" "alb" {
  # El nombre cambia junto con el ALB (de público a interno) para no chocar al reemplazarlo.
  name        = "${local.name}-alb-internal"
  description = "ALB interno: HTTP desde el VPC Link de API Gateway hacia Kong"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP desde el VPC Link"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_link.id]
  }

  lifecycle {
    create_before_destroy = true
  }

  # El ALB solo habla con Kong, dentro de la VPC.
  egress {
    description = "Hacia Kong dentro de la VPC"
    from_port   = 8000
    to_port     = 8100
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }
}

resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "Tareas de ECS: Kong desde el ALB; servicios y RabbitMQ desde el NLB interno"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Kong (proxy y status) desde el ALB publico"
    from_port       = 8000
    to_port         = 8100
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # El NLB interno no preserva la IP de origen con destinos tipo ip: el tráfico llega desde sus IPs privadas
  # dentro de la VPC. Por eso la regla es por el CIDR de la VPC y no por security group.
  ingress {
    description = "Servicios 8081-8088 desde el NLB interno"
    from_port   = 8081
    to_port     = 8088
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  ingress {
    description = "AMQP desde el NLB interno"
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # Excepción revisada: sin NAT Gateway, las tareas salen a internet por su IP pública para descargar las
  # imágenes (GHCR, ECR Public) y llamar APIs externas (Gemini, Wompi). Limitarla por IP no es viable porque
  # esos destinos no tienen rangos fijos. La entrada sí está cerrada.
  #trivy:ignore:AVD-AWS-0104
  egress {
    description = "Salida a internet (imagenes y APIs externas)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "RDS PostgreSQL: solo desde las tareas"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }
}

resource "aws_security_group" "cache" {
  name        = "${local.name}-cache"
  description = "ElastiCache Redis: solo desde las tareas"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }
}
