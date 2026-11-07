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
    condition     = alltrue([for k in keys(var.desired_counts) : contains(["auth", "user", "event", "gateway"], k)])
    error_message = "desired_counts solo acepta auth, user, event y gateway."
  }
}
