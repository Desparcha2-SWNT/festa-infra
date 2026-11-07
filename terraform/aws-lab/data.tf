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
# Sin AUTH: ElastiCache solo acepta token con TLS en tránsito, y los clientes de hoy no usan TLS. El acceso
# queda limitado por el security group a las tareas de ECS.
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = local.name
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.cache_node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.cache.id]
  apply_immediately    = true
}
