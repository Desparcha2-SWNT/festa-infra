# Autoescalado horizontal de los servicios sin estado (SCRUM-135). Apagado por defecto: actívalo con
# `-var enable_autoscaling=true` cuando se quiera mostrar en la sustentación.
#
# Política (propuesta del equipo, ver docs/sustentacion/stateless-contenedores-autoescalado.md):
#   - Métrica: CPU promedio del servicio en ECS (target tracking) al 60 %.
#   - Sube rápido (enfriamiento 60 s) y baja despacio (300 s) para no oscilar con picos cortos.
#   - Mínimo y máximo por servicio en var.autoscaling_limits.
# Solo aplica a servicios con réplicas (> 0). RabbitMQ y Mongo tienen estado y no se autoescalan.
# Cada `apply` devuelve las réplicas a desired_count y el autoescalado las ajusta de nuevo. No se usa ignore_changes
# porque services_desired_count dejaría de poder subir o bajar el entorno.
#
# Nota del Learner Lab: Application Auto Scaling usa el rol vinculado AWSServiceRoleForApplicationAutoScaling_ECSService.
# Si la cuenta del lab no permite crearlo, el apply falla en estos recursos: vuelve a enable_autoscaling=false.

variable "enable_autoscaling" {
  description = "Crea las políticas de autoescalado por CPU de los servicios de ECS."
  type        = bool
  default     = false
}

variable "autoscaling_cpu_target" {
  description = "CPU promedio (%) que el autoescalado intenta mantener."
  type        = number
  default     = 60
}

variable "autoscaling_limits" {
  description = "Réplicas mínimas y máximas por servicio cuando enable_autoscaling = true."
  type        = map(object({ min = number, max = number }))
  default = {
    gateway      = { min = 1, max = 3 }
    auth         = { min = 1, max = 2 }
    user         = { min = 1, max = 2 }
    event        = { min = 1, max = 3 } # el mapa es lo más consultado
    booking      = { min = 1, max = 3 } # ráfagas al escanear QR en la entrada de un evento
    payment      = { min = 1, max = 2 }
    ai           = { min = 1, max = 2 } # el límite real es el costo del LLM (RNF8), no la CPU
    notification = { min = 1, max = 2 }
    analytics    = { min = 1, max = 2 }
  }
}

locals {
  ecs_services = merge(
    { for k, s in aws_ecs_service.service : k => s.name },
    { gateway = aws_ecs_service.gateway.name },
  )
  autoscaled = var.enable_autoscaling ? {
    for k, name in local.ecs_services : k => name
    if lookup(var.desired_counts, k, var.services_desired_count) > 0 && contains(keys(var.autoscaling_limits), k)
  } : {}
}

resource "aws_appautoscaling_target" "service" {
  for_each = local.autoscaled

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${each.value}"
  min_capacity       = var.autoscaling_limits[each.key].min
  max_capacity       = var.autoscaling_limits[each.key].max
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each = local.autoscaled

  name               = "${local.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.service[each.key].service_namespace
  scalable_dimension = aws_appautoscaling_target.service[each.key].scalable_dimension
  resource_id        = aws_appautoscaling_target.service[each.key].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_cpu_target
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
