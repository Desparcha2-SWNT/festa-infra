# EFS para MongoDB: el almacenamiento local de una tarea de Fargate se pierde al reemplazarla (reinicio, nuevo
# despliegue o cambio de secreto). Con /data/db en EFS, el historial de chat (ai), las bandejas (notification) y
# los agregados (analytics) sobreviven a la tarea.
#
# Un mount target por subred (una por zona), cifrado en reposo y en tránsito. El access point fija el dueño
# (uid/gid 999 = usuario `mongodb` de la imagen oficial) y crea el directorio raíz con permisos 0700, así
# mongod puede escribir sin correr como root sobre el volumen.

resource "aws_efs_file_system" "mongo" {
  creation_token   = "${local.name}-mongo"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = { Name = "${local.name}-mongo" }
}

resource "aws_security_group" "efs" {
  name        = "${local.name}-efs"
  description = "EFS de MongoDB: NFS solo desde las tareas"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "NFS desde las tareas de ECS"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }
}

resource "aws_efs_mount_target" "mongo" {
  for_each = toset(local.subnet_ids)

  file_system_id  = aws_efs_file_system.mongo.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "mongo" {
  file_system_id = aws_efs_file_system.mongo.id

  posix_user {
    uid = 999
    gid = 999
  }

  root_directory {
    path = "/mongo"
    creation_info {
      owner_uid   = 999
      owner_gid   = 999
      permissions = "0700"
    }
  }

  tags = { Name = "${local.name}-mongo" }
}
