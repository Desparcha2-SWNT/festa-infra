# ECS Fargate: un servicio de ECS por microservicio, más RabbitMQ y Kong.
#
# Rol: el Learner Lab no deja crear roles IAM, así que LabRole hace de rol de ejecución (descarga de imágenes,
# logs, lectura de Secrets Manager) y de rol de tarea.
#
# Archivos: Fargate no monta archivos. Los servicios leen las llaves JWT de una ruta (JWT_PUBLIC_KEY_PATH,
# JWT_PRIVATE_KEY_PATH), así que cada contenedor arranca con un `sh -c` que escribe la PEM recibida por
# variable en /tmp y luego hace exec del mismo comando que la imagen. No hay que cambiar los servicios.

data "aws_iam_role" "lab" {
  name = "LabRole"
}

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}

locals {
  # Imágenes de Docker Hub servidas desde ECR Public: evita el límite de descargas anónimas de Docker Hub
  # desde IPs de AWS.
  rabbitmq_image = "public.ecr.aws/docker/library/rabbitmq:3.13-management-alpine"
  postgres_image = "public.ecr.aws/docker/library/postgres:16-alpine"
  alpine_image   = "public.ecr.aws/docker/library/alpine:3.20"
  mongo_image    = "public.ecr.aws/docker/library/mongo:7.0"

  image = { for s in local.app_names :
    s => "${var.image_registry}/festa-${s == "gateway" ? "gateway" : "${s}-service"}:${lookup(var.image_tags, s, var.image_tag)}"
  }

  log = { for s in concat(local.app_names, ["rabbitmq", "mongo", "db-init"]) : s => {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.main.name
      awslogs-region        = var.region
      awslogs-stream-prefix = s
    }
  } }

  write_public_key  = "printf '%s\\n' \"$JWT_PUBLIC_KEY\" > /tmp/jwt_public.pem"
  write_private_key = "printf '%s\\n' \"$JWT_PRIVATE_KEY\" > /tmp/jwt_private.pem"
  write_qr_secret   = "printf '%s' \"$QR_SIGNING_SECRET\" > /tmp/qr_signing.key"
  write_fcm_account = "printf '%s' \"$FCM_SERVICE_ACCOUNT_JSON\" > /tmp/firebase-service-account.json"

  amqp_env = [
    { name = "JWT_ISSUER", value = "festa-auth" },
    { name = "JWT_PUBLIC_KEY_PATH", value = "/tmp/jwt_public.pem" },
    { name = "LOG_LEVEL", value = "info" },
  ]

  # Definición de cada microservicio. Los comandos replican el ENTRYPOINT de su Dockerfile.
  services = {
    auth = {
      cpu     = 512
      memory  = 1024
      port    = 8081
      command = "${local.write_private_key} && ${local.write_public_key} && exec java -jar app.jar"
      environment = concat(local.amqp_env, [
        { name = "SERVER_PORT", value = "8081" },
        { name = "DB_URL", value = "jdbc:postgresql://${aws_db_instance.main.address}:5432/auth_db" },
        { name = "DB_USER", value = "auth_svc" },
        { name = "JWT_PRIVATE_KEY_PATH", value = "/tmp/jwt_private.pem" },
        { name = "JWT_ACCESS_TTL_MINUTES", value = "15" },
        { name = "JWT_REFRESH_TTL_DAYS", value = "30" },
        { name = "GOOGLE_CLIENT_IDS", value = var.google_client_ids },
        { name = "ALLOWED_EMAIL_DOMAIN", value = var.allowed_email_domain },
        { name = "ADMIN_EMAIL", value = var.admin_email },
      ])
      secrets = {
        AMQP_URL           = "AMQP_URL"
        DB_PASSWORD        = "AUTH_DB_PASSWORD"
        JWT_PRIVATE_KEY    = "JWT_PRIVATE_KEY"
        JWT_PUBLIC_KEY     = "JWT_PUBLIC_KEY"
        PII_ENCRYPTION_KEY = "PII_ENCRYPTION_KEY"
        ADMIN_PASSWORD     = "ADMIN_PASSWORD"
      }
    }
    user = {
      cpu     = 512
      memory  = 1024
      port    = 8082
      command = "${local.write_public_key} && exec java $JAVA_OPTS -jar /app/app.jar"
      environment = concat(local.amqp_env, [
        { name = "SERVER_PORT", value = "8082" },
        { name = "DB_URL", value = "jdbc:postgresql://${aws_db_instance.main.address}:5432/user_db" },
        { name = "DB_USER", value = "user_svc" },
        { name = "REDIS_HOST", value = aws_elasticache_cluster.redis.cache_nodes[0].address },
        { name = "REDIS_PORT", value = "6379" },
        { name = "REDIS_DATABASE", value = "2" },
        { name = "AUTH_BASE_URL", value = local.internal_url["auth"] },
      ])
      secrets = {
        AMQP_URL           = "AMQP_URL"
        DB_PASSWORD        = "USER_DB_PASSWORD"
        JWT_PUBLIC_KEY     = "JWT_PUBLIC_KEY"
        PII_ENCRYPTION_KEY = "PII_ENCRYPTION_KEY"
      }
    }
    event = {
      cpu     = 256
      memory  = 512
      port    = 8083
      command = "${local.write_public_key} && exec node src/server.js"
      environment = concat(local.amqp_env, [
        { name = "PORT", value = "8083" },
      ])
      secrets = {
        AMQP_URL       = "AMQP_URL"
        DATABASE_URL   = "EVENT_DATABASE_URL"
        JWT_PUBLIC_KEY = "JWT_PUBLIC_KEY"
      }
    }
    # RF7, RF10: asistencia y QR de un solo uso.
    booking = {
      cpu     = 256
      memory  = 512
      port    = 8084
      command = "${local.write_public_key} && ${local.write_qr_secret} && exec node src/server.js"
      environment = concat(local.amqp_env, [
        { name = "PORT", value = "8084" },
        { name = "QR_SIGNING_SECRET_PATH", value = "/tmp/qr_signing.key" },
        { name = "RESERVATION_HOLD_MINUTES", value = "15" },
      ])
      secrets = {
        AMQP_URL          = "AMQP_URL"
        DATABASE_URL      = "BOOKING_DATABASE_URL"
        JWT_PUBLIC_KEY    = "JWT_PUBLIC_KEY"
        QR_SIGNING_SECRET = "QR_SIGNING_SECRET"
      }
    }
    # RF11: boletería con Wompi. La simulación de pagos queda apagada salvo que se pida (demos).
    payment = {
      cpu     = 256
      memory  = 512
      port    = 8085
      command = "${local.write_public_key} && exec node src/server.js"
      environment = concat(local.amqp_env, [
        { name = "PORT", value = "8085" },
        { name = "WOMPI_ENV", value = var.wompi_env },
        { name = "WOMPI_PUBLIC_KEY", value = var.wompi_public_key },
        { name = "WOMPI_REDIRECT_URL", value = var.wompi_redirect_url },
        { name = "WOMPI_FEE_PERCENT", value = "2.99" },
        { name = "WOMPI_FEE_FIXED_CENTS", value = "0" },
        { name = "IVA_PERCENT", value = "19" },
        { name = "COMMISSION_PERCENT", value = tostring(var.commission_percent) },
        { name = "COMMISSION_FIXED_CENTS", value = "0" },
        { name = "RESERVATION_HOLD_MINUTES", value = "15" },
        { name = "PAYMENTS_ALLOW_SIMULATION", value = tostring(var.payments_allow_simulation) },
      ])
      secrets = {
        AMQP_URL               = "AMQP_URL"
        DATABASE_URL           = "PAYMENT_DATABASE_URL"
        JWT_PUBLIC_KEY         = "JWT_PUBLIC_KEY"
        WOMPI_PRIVATE_KEY      = "WOMPI_PRIVATE_KEY"
        WOMPI_EVENTS_SECRET    = "WOMPI_EVENTS_SECRET"
        WOMPI_INTEGRITY_SECRET = "WOMPI_INTEGRITY_SECRET"
      }
    }
    # RF8, RF9: IA Generativa. Sin LLM_API_KEY usa respuestas locales de ejemplo (sin costo).
    ai = {
      cpu     = 256
      memory  = 512
      port    = 8086
      command = "${local.write_public_key} && exec uvicorn app.main:app --host 0.0.0.0 --port 8086 --proxy-headers --forwarded-allow-ips='*'"
      environment = concat(local.amqp_env, [
        { name = "PORT", value = "8086" },
        { name = "REDIS_URL", value = "redis://${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379/1" },
        { name = "LLM_PROVIDER", value = var.llm_provider },
        { name = "LLM_CHAT_MODEL", value = var.llm_chat_model },
        { name = "LLM_DESCRIPTION_MODEL", value = var.llm_description_model },
        { name = "AI_CHAT_RATE_LIMIT_PER_MIN", value = "10" },
      ])
      secrets = {
        AMQP_URL       = "AMQP_URL"
        MONGO_URL      = "AI_MONGO_URL"
        JWT_PUBLIC_KEY = "JWT_PUBLIC_KEY"
        LLM_API_KEY    = "LLM_API_KEY"
      }
    }
    # RF12: push con Firebase. Sin cuenta de servicio, las notificaciones quedan solo en la bandeja.
    notification = {
      cpu     = 256
      memory  = 512
      port    = 8087
      command = "${local.write_public_key} && ${local.write_fcm_account} && exec node src/server.js"
      environment = concat(local.amqp_env, [
        { name = "PORT", value = "8087" },
        { name = "FCM_SERVICE_ACCOUNT_PATH", value = "/tmp/firebase-service-account.json" },
      ])
      secrets = {
        AMQP_URL                 = "AMQP_URL"
        MONGO_URL                = "NOTIFICATION_MONGO_URL"
        JWT_PUBLIC_KEY           = "JWT_PUBLIC_KEY"
        FCM_SERVICE_ACCOUNT_JSON = "FCM_SERVICE_ACCOUNT_JSON"
      }
    }
    # RF15: panel del comercio y KPIs.
    analytics = {
      cpu     = 256
      memory  = 512
      port    = 8088
      command = "${local.write_public_key} && exec node src/server.js"
      environment = concat(local.amqp_env, [
        { name = "PORT", value = "8088" },
      ])
      secrets = {
        AMQP_URL       = "AMQP_URL"
        MONGO_URL      = "ANALYTICS_MONGO_URL"
        JWT_PUBLIC_KEY = "JWT_PUBLIC_KEY"
      }
    }
  }
}

# ------------------------------------------------------------------ inicialización de la base de datos
resource "aws_ecs_task_definition" "db_init" {
  family                   = "${local.name}-db-init"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = data.aws_iam_role.lab.arn
  task_role_arn            = data.aws_iam_role.lab.arn

  container_definitions = jsonencode([{
    name       = "db-init"
    image      = local.postgres_image
    essential  = true
    entryPoint = ["sh", "-c"]
    command    = ["printf '%s' \"$DB_INIT_SCRIPT\" > /tmp/db-init.sh && exec sh /tmp/db-init.sh"]
    environment = [
      { name = "PGHOST", value = aws_db_instance.main.address },
      { name = "PGUSER", value = aws_db_instance.main.username },
      { name = "DB_INIT_SCRIPT", value = file("${path.module}/db-init.sh") },
    ]
    secrets = [for env, key in {
      PGPASSWORD          = "DB_MASTER_PASSWORD"
      AUTH_DB_PASSWORD    = "AUTH_DB_PASSWORD"
      USER_DB_PASSWORD    = "USER_DB_PASSWORD"
      EVENT_DB_PASSWORD   = "EVENT_DB_PASSWORD"
      BOOKING_DB_PASSWORD = "BOOKING_DB_PASSWORD"
      PAYMENT_DB_PASSWORD = "PAYMENT_DB_PASSWORD"
    } : { name = env, valueFrom = local.secret_ref[key] }]
    logConfiguration = local.log["db-init"]
  }])
}

# Corre la tarea de inicialización y espera a que termine bien. Vuelve a correr si cambia el script, la
# instancia de RDS o las contraseñas. Necesita el AWS CLI donde corre Terraform (el runner de GitHub lo trae).
resource "terraform_data" "db_init" {
  triggers_replace = [
    aws_db_instance.main.id,
    aws_ecs_task_definition.db_init.arn,
    aws_secretsmanager_secret_version.app.version_id,
  ]

  provisioner "local-exec" {
    interpreter = ["bash"]
    command     = "${path.module}/run-task.sh"
    environment = {
      AWS_REGION      = var.region
      CLUSTER         = aws_ecs_cluster.main.name
      TASK_DEFINITION = aws_ecs_task_definition.db_init.arn
      SUBNETS         = join(",", local.subnet_ids)
      SECURITY_GROUP  = aws_security_group.tasks.id
    }
  }
}

# ------------------------------------------------------------------ RabbitMQ
# Amazon MQ está bloqueado en el Learner Lab. RabbitMQ corre como tarea con un contenedor auxiliar que carga
# la topología de contracts/rabbitmq/definitions.json por la API de administración, igual que el servicio
# rabbitmq-topology del compose. Sin volumen: si la tarea se reinicia, la topología se vuelve a cargar y los
# mensajes en cola se pierden (aceptable en el lab; las colas son durables dentro de la vida de la tarea).
resource "aws_ecs_task_definition" "rabbitmq" {
  family                   = "${local.name}-rabbitmq"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = data.aws_iam_role.lab.arn
  task_role_arn            = data.aws_iam_role.lab.arn

  container_definitions = jsonencode([
    {
      name         = "rabbitmq"
      image        = local.rabbitmq_image
      essential    = true
      portMappings = [{ containerPort = 5672, protocol = "tcp" }]
      environment = [
        { name = "RABBITMQ_DEFAULT_USER", value = "festa" },
        { name = "RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS", value = "+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none" },
      ]
      secrets = [{ name = "RABBITMQ_DEFAULT_PASS", valueFrom = local.secret_ref["RABBITMQ_PASSWORD"] }]
      # Sin rabbitmq-diagnostics: el health check corre como root y, si llega antes que el servidor, crea
      # /var/lib/rabbitmq/.erlang.cookie con dueño root y RabbitMQ no arranca (eacces). Mismo chequeo que el compose.
      healthCheck      = { command = ["CMD-SHELL", "nc -z 127.0.0.1 5672 && wget -qO /dev/null http://127.0.0.1:15672/"], interval = 15, timeout = 10, retries = 10, startPeriod = 60 }
      logConfiguration = local.log["rabbitmq"]
    },
    {
      name       = "topology"
      image      = local.alpine_image
      essential  = false
      dependsOn  = [{ containerName = "rabbitmq", condition = "HEALTHY" }]
      entryPoint = ["sh", "-c"]
      command = [join(" && ", [
        "apk add --no-cache curl >/dev/null",
        "printf '%s' \"$DEFINITIONS\" > /tmp/definitions.json",
        "curl -sf --retry 10 --retry-all-errors --retry-delay 5 -u \"festa:$RABBITMQ_PASSWORD\" -H 'content-type: application/json' -X POST --data-binary @/tmp/definitions.json http://127.0.0.1:15672/api/definitions",
        "echo 'topologia cargada'",
      ])]
      environment      = [{ name = "DEFINITIONS", value = file("${path.module}/../../contracts/rabbitmq/definitions.json") }]
      secrets          = [{ name = "RABBITMQ_PASSWORD", valueFrom = local.secret_ref["RABBITMQ_PASSWORD"] }]
      logConfiguration = local.log["rabbitmq"]
    },
  ])
}

resource "aws_ecs_service" "rabbitmq" {
  name            = "rabbitmq"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.rabbitmq.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  # ECS lee los secretos solo al arrancar la tarea: si cambia el secreto, se redespliega.
  force_new_deployment = true
  triggers = {
    secret_version = aws_secretsmanager_secret_version.app.version_id
  }

  # Un solo broker: se apaga el viejo antes de arrancar el nuevo.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.internal["rabbitmq"].arn
    container_name   = "rabbitmq"
    container_port   = 5672
  }

  depends_on = [aws_lb_listener.internal]
}

# ------------------------------------------------------------------ MongoDB
# DocumentDB está bloqueado en el Learner Lab (error 2 del RUNBOOK): Mongo corre como tarea de Fargate para
# ai, notification y analytics, cada uno con su base (ai_db, notification_db, analytics_db). Sin volumen,
# como RabbitMQ: si la tarea se reinicia se pierden los datos (historial de chat, bandejas y agregados se
# reconstruyen con el uso). Para producción: MongoDB Atlas o un volumen EFS.
resource "aws_ecs_task_definition" "mongo" {
  family                   = "${local.name}-mongo"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 1024
  execution_role_arn       = data.aws_iam_role.lab.arn
  task_role_arn            = data.aws_iam_role.lab.arn

  container_definitions = jsonencode([{
    name             = "mongo"
    image            = local.mongo_image
    essential        = true
    command          = ["mongod", "--bind_ip_all", "--wiredTigerCacheSizeGB", "0.25"]
    portMappings     = [{ containerPort = 27017, protocol = "tcp" }]
    environment      = [{ name = "MONGO_INITDB_ROOT_USERNAME", value = "festa" }]
    secrets          = [{ name = "MONGO_INITDB_ROOT_PASSWORD", valueFrom = local.secret_ref["MONGO_ROOT_PASSWORD"] }]
    logConfiguration = local.log["mongo"]
  }])
}

resource "aws_ecs_service" "mongo" {
  name            = "mongo"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.mongo.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  # ECS lee los secretos solo al arrancar la tarea: si cambia el secreto, se redespliega.
  force_new_deployment = true
  triggers = {
    secret_version = aws_secretsmanager_secret_version.app.version_id
  }

  # Una sola instancia: se apaga la vieja antes de arrancar la nueva.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.internal["mongo"].arn
    container_name   = "mongo"
    container_port   = 27017
  }

  depends_on = [aws_lb_listener.internal]
}

# ------------------------------------------------------------------ microservicios
resource "aws_ecs_task_definition" "service" {
  for_each = local.services

  family                   = "${local.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = data.aws_iam_role.lab.arn
  task_role_arn            = data.aws_iam_role.lab.arn

  container_definitions = jsonencode([{
    name             = each.key
    image            = local.image[each.key]
    essential        = true
    entryPoint       = ["sh", "-c"]
    command          = [each.value.command]
    portMappings     = [{ containerPort = each.value.port, protocol = "tcp" }]
    environment      = each.value.environment
    secrets          = [for env, key in each.value.secrets : { name = env, valueFrom = local.secret_ref[key] }]
    logConfiguration = local.log[each.key]
  }])
}

resource "aws_ecs_service" "service" {
  for_each = local.services

  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service[each.key].arn
  desired_count   = lookup(var.desired_counts, each.key, var.services_desired_count)
  launch_type     = "FARGATE"
  # ECS lee los secretos solo al arrancar la tarea: si cambia el secreto, se redespliega.
  force_new_deployment = true
  triggers = {
    secret_version = aws_secretsmanager_secret_version.app.version_id
  }

  # Spring Boot tarda en arrancar con media vCPU: margen antes de que cuenten los health checks.
  health_check_grace_period_seconds = 180

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.internal[each.key].arn
    container_name   = each.key
    container_port   = each.value.port
  }

  depends_on = [aws_lb_listener.internal, terraform_data.db_init, aws_ecs_service.rabbitmq, aws_ecs_service.mongo]
}

# ------------------------------------------------------------------ gateway (Kong)
resource "aws_ecs_task_definition" "gateway" {
  family                   = "${local.name}-gateway"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = data.aws_iam_role.lab.arn
  task_role_arn            = data.aws_iam_role.lab.arn

  container_definitions = jsonencode([{
    name      = "gateway"
    image     = local.image["gateway"]
    essential = true
    portMappings = [
      { containerPort = 8000, protocol = "tcp" },
      { containerPort = 8100, protocol = "tcp" },
    ]
    environment = [
      { name = "AUTH_SERVICE_URL", value = local.internal_url["auth"] },
      { name = "USER_SERVICE_URL", value = local.internal_url["user"] },
      { name = "EVENT_SERVICE_URL", value = local.internal_url["event"] },
      { name = "BOOKING_SERVICE_URL", value = local.internal_url["booking"] },
      { name = "PAYMENT_SERVICE_URL", value = local.internal_url["payment"] },
      { name = "AI_SERVICE_URL", value = local.internal_url["ai"] },
      { name = "NOTIFICATION_SERVICE_URL", value = local.internal_url["notification"] },
      { name = "ANALYTICS_SERVICE_URL", value = local.internal_url["analytics"] },
      # IP real del cliente para el rate limit por IP. API Gateway no la pone en X-Forwarded-For hacia un VPC
      # Link, así que la escribe en X-Real-IP (apigw.tf, sobrescribiendo lo que mande el cliente). Kong solo
      # cree ese encabezado si la petición viene de la VPC (el ALB interno).
      { name = "KONG_TRUSTED_IPS", value = local.vpc_cidr },
      { name = "KONG_REAL_IP_HEADER", value = "X-Real-IP" },
      { name = "KONG_REAL_IP_RECURSIVE", value = "off" },
    ]
    secrets          = [{ name = "JWT_PUBLIC_KEY", valueFrom = local.secret_ref["JWT_PUBLIC_KEY"] }]
    logConfiguration = local.log["gateway"]
  }])
}

resource "aws_ecs_service" "gateway" {
  name            = "gateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = lookup(var.desired_counts, "gateway", var.services_desired_count)
  launch_type     = "FARGATE"
  # ECS lee los secretos solo al arrancar la tarea: si cambia el secreto, se redespliega.
  force_new_deployment = true
  triggers = {
    secret_version = aws_secretsmanager_secret_version.app.version_id
  }

  health_check_grace_period_seconds = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "gateway"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.gateway_http]
}
