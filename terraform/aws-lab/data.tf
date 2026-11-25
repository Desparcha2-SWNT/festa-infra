# Datos: una instancia de RDS PostgreSQL con una base y un usuario por servicio (igual que postgres/init en
# el compose) y una caché de ElastiCache Redis con bases lógicas separadas (0 mapa, 1 rate limit de IA,
# 2 perfiles de user-service).
resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = local.subnet_ids
}

resource "aws_db_instance" "main" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  # Cifrado en reposo con AES-256 (llave administrada por AWS).
  storage_encrypted = true

  username = "festa_admin"
  password = random_password.db["master"].result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  # Entorno de laboratorio que se destruye y se vuelve a crear con scripts: sin snapshot final ni respaldos.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

resource "aws_elasticache_subnet_group" "main" {
  name       = local.name
  subnet_ids = local.subnet_ids
}

# Nodo único con cluster mode desactivado: es el único modo en que Redis permite usar las bases 0, 1 y 2.
# Es un replication group de un solo nodo (no aws_elasticache_cluster) porque solo así ElastiCache permite
# cifrado en reposo (SCRUM-48): user-service usa la base 2 como caché de perfiles.
# Sin AUTH ni TLS en tránsito: ElastiCache solo acepta token con TLS, y los clientes de hoy no usan TLS. El
# acceso queda limitado por el security group a las tareas de ECS, dentro de la VPC.
# AVD-AWS-0051 (TLS en tránsito): excepción aceptada por lo anterior; ver docs/seguridad/cifrado.md.
#trivy:ignore:AVD-AWS-0051
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = local.name
  description                = "Festa: caché del mapa (db 0), rate limit de IA (db 1) y perfiles (db 2)"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = var.cache_node_type
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  parameter_group_name       = "default.redis7"
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.cache.id]
  # Cifrado en reposo con AES-256 (llave administrada por AWS).
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false
  apply_immediately          = true
}
