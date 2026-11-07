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

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB publico: HTTP desde internet hacia Kong"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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

  egress {
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
