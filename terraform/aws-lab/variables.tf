variable "region" {
  description = "Región del Learner Lab (solo permite us-east-1 y us-west-2)."
  type        = string
  default     = "us-east-1"
}

variable "env" {
  description = "Nombre del entorno; va en los nombres y en las etiquetas de los recursos."
  type        = string
  default     = "lab"
}

variable "image_registry" {
  description = "Registro de las imágenes de los servicios. El CD de cada repo publica en GHCR al fusionar a main."
  type        = string
  default     = "ghcr.io/desparcha2-swnt"
}

variable "image_tag" {
  description = "Tag de imagen para todos los servicios (latest o sha-<commit>)."
  type        = string
  default     = "latest"
}

variable "image_tags" {
  description = "Tag por servicio, gana sobre image_tag. Ej.: { auth = \"sha-1a2b3c4\" }."
  type        = map(string)
  default     = {}
}

variable "services_desired_count" {
  description = "Réplicas de cada servicio. 0 levanta solo la base (red, RDS, Redis, RabbitMQ y balanceadores), útil mientras no haya imágenes en GHCR."
  type        = number
  default     = 1
}

variable "db_instance_class" {
  description = "Clase de RDS. El Learner Lab solo permite hasta tamaño medium."
  type        = string
  default     = "db.t3.micro"
}

variable "cache_node_type" {
  description = "Nodo de ElastiCache."
  type        = string
  default     = "cache.t3.micro"
}

variable "allowed_email_domain" {
  description = "Dominio de correo permitido para registrarse (piloto ECI)."
  type        = string
  default     = "escuelaing.edu.co"
}

variable "admin_email" {
  description = "Cuenta de administrador que auth-service crea al arrancar."
  type        = string
  default     = "admin@escuelaing.edu.co"
}

variable "google_client_ids" {
  description = "Client IDs de Google Sign-In separados por coma (vacío = login con Google desactivado)."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Días que se guardan los logs en CloudWatch."
  type        = number
  default     = 3
}

variable "desired_counts" {
  description = "Réplicas por servicio; gana sobre services_desired_count. Sirve para levantar solo los servicios que ya tienen imagen en GHCR. Ej.: { auth = 1, gateway = 1, user = 0, event = 0 }."
  type        = map(number)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.desired_counts) : contains(["auth", "user", "event", "booking", "payment", "ai", "notification", "analytics", "gateway"], k)])
    error_message = "desired_counts solo acepta auth, user, event, booking, payment, ai, notification, analytics y gateway."
  }
}

# ------------------------------------------------------------------ pagos (RF11)
variable "wompi_env" {
  description = "sandbox o production."
  type        = string
  default     = "sandbox"
}

variable "wompi_public_key" {
  description = "Llave pública de Wompi (pub_test_... en sandbox)."
  type        = string
  default     = "pub_test_xxx"
}

variable "wompi_private_key" {
  description = "Llave privada de Wompi. Pásala con TF_VAR_wompi_private_key, nunca en el repo."
  type        = string
  default     = "prv_test_xxx"
  sensitive   = true
}

variable "wompi_events_secret" {
  description = "Secreto de eventos de Wompi (firma del webhook)."
  type        = string
  default     = "test_events_xxx"
  sensitive   = true
}

variable "wompi_integrity_secret" {
  description = "Secreto de integridad de Wompi (firma del checkout)."
  type        = string
  default     = "test_integrity_xxx"
  sensitive   = true
}

variable "wompi_redirect_url" {
  description = "A dónde vuelve el usuario tras pagar (deep link de la app)."
  type        = string
  default     = "festa://payments/result"
}

variable "commission_percent" {
  description = "Comisión de Festa por boleta (RN2); debe superar 2,99 % + IVA de Wompi."
  type        = number
  default     = 8
}

variable "payments_allow_simulation" {
  description = "Solo para demos sin Wompi: habilita POST /api/payments/orders/{id}/simulate."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------ IA (RF8, RF9) y push (RF12)
variable "llm_provider" {
  description = "gemini, openai, anthropic u ollama. Sin llm_api_key, ai-service usa respuestas locales de ejemplo."
  type        = string
  default     = "gemini"
}

variable "llm_api_key" {
  description = "API key del proveedor de IA. Pásala con TF_VAR_llm_api_key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "llm_chat_model" {
  description = "Modelo de bajo costo para el chat (RNF8)."
  type        = string
  default     = "gemini-2.5-flash"
}

variable "llm_description_model" {
  description = "Modelo para las descripciones (RF9)."
  type        = string
  default     = "gemini-2.5-flash"
}

variable "fcm_service_account_json" {
  description = "JSON de la cuenta de servicio de Firebase. {} = sin push, solo bandeja."
  type        = string
  default     = "{}"
  sensitive   = true
}
