# Observabilidad en AWS con CloudWatch (Prometheus y Grafana solo corren en Docker Compose).
#
# - Peticiones por código: Kong escribe una línea por petición en su log de acceso (formato «festa» de
#   festa-gateway: IP [hora] "MÉTODO RUTA PROTOCOLO" código bytes segundos "agente"). Los filtros de métricas
#   de abajo cuentan cada línea y la separan por clase (2xx, 4xx, 5xx) y por código exacto, y toman la latencia.
#   Cubre a todos los servicios, porque toda petición de la app pasa por Kong.
# - Salud de cada servicio: Container Insights (tareas en marcha, CPU y memoria por servicio de ECS).
# - Alarmas sobre lo anterior y un tablero que junta todo, con los últimos errores 5xx del log.
#
# El Learner Lab no deja crear temas de SNS con suscripciones útiles: las alarmas no notifican, se ven en la
# consola de CloudWatch (Alarmas) y en el tablero.

locals {
  metrics_namespace = "Festa/Gateway"
  # Una línea de acceso de Kong, separada por espacios: los corchetes y las comillas agrupan un solo campo.
  kong_access_fields = "ip, time, request=\"*HTTP/*\", status, bytes, latency, agent"

  status_classes = {
    "2xx" = "2*"
    "3xx" = "3*"
    "4xx" = "4*"
    "5xx" = "5*"
  }

  monitored_services = concat(sort(keys(local.services)), ["gateway"])
}

resource "aws_cloudwatch_log_metric_filter" "gateway_requests" {
  name           = "${local.name}-gateway-peticiones"
  log_group_name = aws_cloudwatch_log_group.main.name
  pattern        = "[${local.kong_access_fields}]"

  metric_transformation {
    name      = "Peticiones"
    namespace = local.metrics_namespace
    value     = "1"
    unit      = "Count"
    # Código exacto como dimensión (200, 401, 404, 429, 500...): pocos valores posibles.
    dimensions = {
      Codigo = "$status"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "gateway_status_class" {
  for_each = local.status_classes

  name           = "${local.name}-gateway-${each.key}"
  log_group_name = aws_cloudwatch_log_group.main.name
  pattern        = "[ip, time, request=\"*HTTP/*\", status=${each.value}, bytes, latency, agent]"

  metric_transformation {
    name          = "Respuestas${each.key}"
    namespace     = local.metrics_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "gateway_latency" {
  name           = "${local.name}-gateway-latencia"
  log_group_name = aws_cloudwatch_log_group.main.name
  pattern        = "[${local.kong_access_fields}]"

  metric_transformation {
    name      = "LatenciaSegundos"
    namespace = local.metrics_namespace
    value     = "$latency"
    unit      = "Seconds"
  }
}

# ---------- Alarmas ----------

resource "aws_cloudwatch_metric_alarm" "gateway_5xx" {
  alarm_name          = "${local.name}-errores-5xx"
  alarm_description   = "Más de 5 respuestas 5xx en 5 minutos: buscar en el tablero «Últimos errores 5xx» la ruta y la hora, y en el log del servicio el X-Correlation-ID."
  namespace           = local.metrics_namespace
  metric_name         = "Respuestas5xx"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "gateway_latency" {
  alarm_name          = "${local.name}-latencia-p95"
  alarm_description   = "La latencia p95 de las peticiones supera 2 s (RNF del mapa) durante 10 minutos."
  namespace           = local.metrics_namespace
  metric_name         = "LatenciaSegundos"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "gateway_429" {
  alarm_name          = "${local.name}-limite-de-peticiones"
  alarm_description   = "Muchas respuestas 429 de Kong: posible abuso o un cliente en bucle."
  namespace           = local.metrics_namespace
  metric_name         = "Peticiones"
  dimensions          = { Codigo = "429" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 50
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

# Un servicio sin tareas en marcha (Container Insights). Solo para los que se despliegan con réplicas.
resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = toset(local.monitored_services)

  alarm_name          = "${local.name}-${each.key}-sin-tareas"
  alarm_description   = "El servicio ${each.key} no tiene tareas en marcha durante 2 minutos."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = { ClusterName = aws_ecs_cluster.main.name, ServiceName = each.key }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # Sin datos = el servicio no existe o el entorno está apagado: no se trata como caída.
  treat_missing_data = "notBreaching"
}

# ---------- Tablero ----------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-observabilidad"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "Respuestas por clase (todas las peticiones pasan por Kong)"
          region  = var.region
          stat    = "Sum"
          period  = 60
          view    = "timeSeries"
          stacked = true
          metrics = [for k in keys(local.status_classes) : [local.metrics_namespace, "Respuestas${k}", { label = k }]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Latencia de las peticiones (segundos)"
          region = var.region
          period = 60
          view   = "timeSeries"
          metrics = [
            [local.metrics_namespace, "LatenciaSegundos", { stat = "p50", label = "p50" }],
            [local.metrics_namespace, "LatenciaSegundos", { stat = "p95", label = "p95" }],
            [local.metrics_namespace, "LatenciaSegundos", { stat = "p99", label = "p99" }],
          ]
          annotations = { horizontal = [{ value = 2, label = "Meta del mapa: 2 s" }] }
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title   = "Respuestas por código exacto"
          region  = var.region
          period  = 300
          view    = "timeSeries"
          metrics = [[{ expression = "SEARCH('{${local.metrics_namespace},Codigo} MetricName=\"Peticiones\"', 'Sum', 300)", id = "codigos", label = "" }]]
        }
      },
      {
        type = "alarm", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Alarmas"
          alarms = concat(
            [aws_cloudwatch_metric_alarm.gateway_5xx.arn, aws_cloudwatch_metric_alarm.gateway_latency.arn, aws_cloudwatch_metric_alarm.gateway_429.arn],
            [for s in local.monitored_services : aws_cloudwatch_metric_alarm.service_down[s].arn]
          )
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 8, height = 6
        properties = {
          title   = "Tareas en marcha por servicio"
          region  = var.region
          stat    = "Minimum"
          period  = 60
          view    = "timeSeries"
          metrics = [for s in local.monitored_services : ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", s]]
        }
      },
      {
        type = "metric", x = 8, y = 12, width = 8, height = 6
        properties = {
          title   = "CPU por servicio (%)"
          region  = var.region
          stat    = "Average"
          period  = 60
          view    = "timeSeries"
          metrics = [for s in local.monitored_services : ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", s]]
        }
      },
      {
        type = "metric", x = 16, y = 12, width = 8, height = 6
        properties = {
          title   = "Memoria por servicio (%)"
          region  = var.region
          stat    = "Average"
          period  = 60
          view    = "timeSeries"
          metrics = [for s in local.monitored_services : ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", s]]
        }
      },
      {
        type = "log", x = 0, y = 18, width = 24, height = 7
        properties = {
          title  = "Últimos errores 5xx (log de acceso de Kong)"
          region = var.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.main.name}' | filter @logStream like /^gateway/ | parse @message '* [*] \"* * *\" * * * \"*\"' as ip, hora, metodo, ruta, protocolo, codigo, bytes, segundos, agente | filter codigo like /^5/ | fields @timestamp, metodo, ruta, codigo, segundos | sort @timestamp desc | limit 50"
        }
      },
      {
        type = "log", x = 0, y = 25, width = 24, height = 7
        properties = {
          title  = "Errores en los servicios (logs con nivel error)"
          region = var.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.main.name}' | filter @logStream not like /^gateway/ | filter @message like /(?i)\"level\":\\s*(50|\"error\")|ERROR|Traceback/ | fields @timestamp, @logStream, @message | sort @timestamp desc | limit 50"
        }
      },
    ]
  })
}

output "observability_dashboard_url" {
  description = "Tablero de observabilidad en la consola de CloudWatch."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}
