# Secretos del entorno. Se generan aquí (no hay valores en el repo) y quedan en el estado de Terraform, que
# vive en un bucket S3 cifrado y privado de la cuenta del lab. Las tareas los reciben como variables de
# entorno desde Secrets Manager (ver SECRETS.md).
resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "random_password" "db" {
  for_each = toset(["master", "auth", "user", "event", "booking", "payment"])

  length  = 32
  special = false
}

resource "random_password" "rabbitmq" {
  length  = 32
  special = false
}

resource "random_password" "mongo" {
  length  = 32
  special = false
}

# HMAC de los QR de booking-service (RF10/RNF7).
resource "random_password" "qr" {
  length  = 44
  special = false
}

resource "random_password" "admin" {
  length  = 20
  special = false
}

# 32 bytes en base64, el mismo formato que genera scripts/gen-secrets.sh para PII_ENCRYPTION_KEY.
resource "random_bytes" "pii_key" {
  length = 32
}

locals {
  secret_values = {
    JWT_PRIVATE_KEY     = tls_private_key.jwt.private_key_pem_pkcs8 # PKCS#8, como openssl genpkey; auth-service no lee PKCS#1
    JWT_PUBLIC_KEY      = tls_private_key.jwt.public_key_pem
    PII_ENCRYPTION_KEY  = random_bytes.pii_key.base64
    ADMIN_PASSWORD      = random_password.admin.result
    RABBITMQ_PASSWORD   = random_password.rabbitmq.result
    DB_MASTER_PASSWORD  = random_password.db["master"].result
    AUTH_DB_PASSWORD    = random_password.db["auth"].result
    USER_DB_PASSWORD    = random_password.db["user"].result
    EVENT_DB_PASSWORD   = random_password.db["event"].result
    BOOKING_DB_PASSWORD = random_password.db["booking"].result
    PAYMENT_DB_PASSWORD = random_password.db["payment"].result
    AMQP_URL            = "amqp://festa:${random_password.rabbitmq.result}@${aws_lb.internal.dns_name}:5672"
    EVENT_DATABASE_URL  = "postgres://event_svc:${random_password.db["event"].result}@${aws_db_instance.main.address}:5432/event_db?sslmode=no-verify"

    BOOKING_DATABASE_URL = "postgres://booking_svc:${random_password.db["booking"].result}@${aws_db_instance.main.address}:5432/booking_db?sslmode=no-verify"
    PAYMENT_DATABASE_URL = "postgres://payment_svc:${random_password.db["payment"].result}@${aws_db_instance.main.address}:5432/payment_db?sslmode=no-verify"
    QR_SIGNING_SECRET    = random_password.qr.result
    MONGO_ROOT_PASSWORD  = random_password.mongo.result
    # Usuario raíz con authSource=admin: Mongo es una sola tarea efímera (ecs.tf) y cada servicio usa su base.
    AI_MONGO_URL           = "mongodb://festa:${random_password.mongo.result}@${aws_lb.internal.dns_name}:27017/ai_db?authSource=admin"
    NOTIFICATION_MONGO_URL = "mongodb://festa:${random_password.mongo.result}@${aws_lb.internal.dns_name}:27017/notification_db?authSource=admin"
    ANALYTICS_MONGO_URL    = "mongodb://festa:${random_password.mongo.result}@${aws_lb.internal.dns_name}:27017/analytics_db?authSource=admin"
    # Llegan por variables sensibles (TF_VAR_...), nunca desde el repo. Ningún valor queda vacío: GitHub entrega
    # "" cuando un secreto no existe, y entonces se usan los placeholders de prueba.
    WOMPI_PRIVATE_KEY      = coalesce(var.wompi_private_key, "prv_test_xxx")
    WOMPI_EVENTS_SECRET    = coalesce(var.wompi_events_secret, "test_events_xxx")
    WOMPI_INTEGRITY_SECRET = coalesce(var.wompi_integrity_secret, "test_integrity_xxx")
    # "none" = sin llave: ai-service usa respuestas locales de ejemplo.
    LLM_API_KEY = coalesce(var.llm_api_key, "none")
    # GitHub entrega "" si el secreto no existe: {} = placeholder (sin push).
    FCM_SERVICE_ACCOUNT_JSON = coalesce(var.fcm_service_account_json, "{}")
  }
}

resource "aws_secretsmanager_secret" "app" {
  name        = "${local.name}/app"
  description = "Secretos de Festa (${var.env}): llaves JWT, contraseñas de BD y RabbitMQ, llave PII"
  # Sin ventana de recuperación: el lab se destruye y se vuelve a crear con el mismo nombre.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode(local.secret_values)
}

# valueFrom de ECS para una llave del secreto JSON: <arn>:<llave>::
locals {
  secret_ref = { for k, _ in local.secret_values : k => "${aws_secretsmanager_secret.app.arn}:${k}::" }
}
