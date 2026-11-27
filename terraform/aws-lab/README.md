# Despliegue en el AWS Academy Learner Lab

Terraform que levanta Festa en AWS (SCRUM-134, ADR 0001). Lo corre el workflow
[`Deploy AWS lab`](../../.github/workflows/deploy-lab.yml), o una persona desde su equipo.

**Para volver a desplegar paso a paso, y con todos los errores conocidos y su solución: [RUNBOOK.md](RUNBOOK.md).**

## Qué crea

```
internet ──HTTPS──► API Gateway ──VPC Link──► ALB interno ──► Kong (festa-gateway) ──► NLB interno ──► auth :8081 · user :8082 · event :8083
                                                                                                │    booking :8084 · payment :8085 · ai :8086
                                                                                                │    notification :8087 · analytics :8088
                                                                                                ├──► RabbitMQ :5672
                                                                                                └──► MongoDB :27017 (ai, notification, analytics)
                    servicios ──► RDS PostgreSQL 16 (una base y un usuario por servicio)
                    user-service ──► ElastiCache Redis (db 2)
```

| Pieza | Servicio de AWS | Notas |
|---|---|---|
| Cómputo | ECS Fargate | Un servicio de ECS por microservicio, con las imágenes de GHCR |
| Entrada | API Gateway (HTTP API) | HTTPS con certificado de AWS (`https://<id>.execute-api.us-east-1.amazonaws.com`). Límite global de 100 req/s (picos de 200) y logs de acceso en `/apigw/festa-lab`. Corta a los 30 s |
| Hacia Kong | VPC Link → ALB interno | El ALB no tiene IP pública. API Gateway escribe la IP del cliente en `X-Real-IP` (sobrescribiendo la que mande el cliente) y Kong la usa para el rate limit por IP |
| Entre servicios | NLB interno | Un puerto por servicio. Reemplaza el DNS por nombre (ver restricciones) |
| PostgreSQL | RDS `db.t3.micro`, cifrado en reposo | `db-init.sh` crea las bases y usuarios, como `postgres/init` del compose |
| Redis | ElastiCache `cache.t3.micro` | Un nodo, sin modo clúster, para poder usar las bases 0, 1 y 2 |
| RabbitMQ | Tarea de Fargate | Carga la topología de `contracts/rabbitmq/definitions.json` al arrancar |
| MongoDB | Tarea de Fargate (`mongo:7.0`) con `/data/db` en EFS | DocumentDB está bloqueado. EFS cifrado (reposo y tránsito) con access point uid 999: los datos de ai, notification y analytics sobreviven a reinicios y despliegues (`efs.tf`) |
| Secretos | Secrets Manager | Llaves JWT, contraseñas y llave PII, generadas por Terraform |
| Logs | CloudWatch Logs `/ecs/festa-lab` | 3 días de retención |
| Observabilidad | CloudWatch: Container Insights, métricas desde el log de Kong, alarmas y el tablero `festa-lab-observabilidad` | `observability.tf` |

## Restricciones del Learner Lab (verificadas el 7-nov-2026)

- **No hay Cloud Map** (`servicediscovery:*` da AccessDenied): ECS no resuelve `auth-service` por nombre. Por
  eso existe el NLB interno, y Kong recibe las URLs por variables de entorno (festa-gateway#5).
- **No hay Amazon MQ** (explicit deny): RabbitMQ corre como contenedor.
- **No se pueden crear roles IAM ni un proveedor OIDC**: todo usa `LabRole`, y GitHub Actions entra con las
  credenciales temporales de la sesión del lab.
- **RDS solo hasta tamaño medium** y solo las regiones us-east-1 y us-west-2.
- **No hay CloudFront** (AccessDenied) ni dominio propio para un certificado de ACM: el HTTPS lo da API
  Gateway, que sí está permitido.
- Las tareas usan las subredes públicas de la VPC por defecto con IP pública, para no pagar un NAT Gateway.
  Nada entra desde internet salvo por API Gateway: lo impiden los security groups, y los balanceadores son internos.

## Desplegar

1. Enciende el lab y copia el bloque `[default]` de **AWS Details → AWS CLI**.
2. Guarda las credenciales en GitHub (vencen con la sesión, unas 4 horas):
   ```bash
   ./scripts/aws-lab/set-github-creds.sh     # pega el bloque y termina con Ctrl+D
   ```
3. En GitHub: **Actions → Deploy AWS lab → Run workflow**, con `apply`. El resumen muestra la URL de la API.
4. **Al terminar, corre el mismo workflow con `destroy`.** Los créditos se siguen gastando aunque se cierre la
   sesión del lab.

El primer despliegue tarda unos 15 minutos (RDS es lo más lento). Con `services_desired_count = 0` se levanta
solo la base, útil mientras no haya imágenes en GHCR.

### Desde un equipo

```bash
export AWS_REGION=us-east-1     # con las credenciales del lab en ~/.aws/credentials
BUCKET=$(../../scripts/aws-lab/bootstrap-state.sh)
terraform init -backend-config="bucket=$BUCKET" -backend-config="key=lab/terraform.tfstate" -backend-config="region=us-east-1"
terraform apply
terraform destroy
```

El estado vive en el bucket `festa-tfstate-<cuenta>`, con bloqueo (`use_lockfile`) y versionado. Así, el
workflow y cualquier persona del equipo trabajan sobre el mismo estado.

## Observabilidad

Prometheus y Grafana corren solo en Docker Compose. En AWS la observabilidad es CloudWatch (`observability.tf`); la URL del tablero sale en el output `observability_dashboard_url`.

| Qué se ve | De dónde sale |
|---|---|
| Peticiones por clase (2xx, 3xx, 4xx, 5xx) y por código exacto | Filtros de métricas sobre el log de acceso de Kong: toda petición de la app pasa por Kong (namespace `Festa/Gateway`) |
| Latencia p50, p95 y p99 | El tiempo de respuesta de esa misma línea de Kong |
| Tareas en marcha, CPU y memoria por servicio | Container Insights (`ECS/ContainerInsights`) y `AWS/ECS` |
| Últimos errores 5xx (método, ruta, código, tiempo) | Consulta de Logs Insights sobre el log de Kong |
| Errores dentro de los servicios | Consulta de Logs Insights sobre los logs con nivel error |

**Alarmas** (no notifican: el Learner Lab no permite SNS útil; se ven en CloudWatch → Alarmas y en el tablero):

| Alarma | Cuándo salta | Qué hacer |
|---|---|---|
| `festa-lab-errores-5xx` | Más de 5 respuestas 5xx en 5 minutos | En «Últimos errores 5xx» ver la ruta y la hora; en el log del servicio de esa ruta buscar el error y su `X-Correlation-ID` (Kong lo pone en cada petición y los servicios lo propagan a sus logs y mensajes) |
| `festa-lab-latencia-p95` | p95 por encima de 2 s durante 10 minutos | Revisar CPU y memoria del servicio en el tablero; si está al tope, subir réplicas (`desired_counts`) o activar `enable_autoscaling` |
| `festa-lab-limite-de-peticiones` | Más de 50 respuestas 429 en 5 minutos | Un cliente en bucle o abuso: ver la ruta en el log de Kong |
| `festa-lab-<servicio>-sin-tareas` | Un servicio sin tareas durante 2 minutos | Ver los eventos del servicio en ECS (por qué se detuvo la tarea) y su log; ECS intenta reemplazarla solo |

Los errores de los mensajes entre servicios no pasan por Kong: se reintentan y, si siguen fallando, van a la cola `*.dlq` de RabbitMQ (consola de RabbitMQ o el tablero de Grafana en local).

Costo: Container Insights cobra métricas por tarea y los filtros de métricas, métricas personalizadas; con un entorno encendido solo durante las pruebas son centavos por sesión.

## Imágenes

Los servicios usan `ghcr.io/desparcha2-swnt/festa-<servicio>:<tag>`, que publica el CD de cada repo al fusionar
a `main`. Fargate las descarga sin credenciales, así que **los paquetes de GHCR tienen que ser públicos**
(Settings del paquete → Change visibility). Los repos ya son públicos, así que no se expone nada nuevo.

## Pendiente

- La URL de API Gateway cambia cada vez que el entorno se destruye y se vuelve a crear. Hay que actualizar la
  variable `API_BASE_URL` de festa-mobile con la salida `api_base_url` antes de publicar un APK.
- Los 8 servicios están definidos. booking, payment, ai, notification y analytics necesitan su imagen en GHCR
  (CD al fusionar a `main`); mientras no exista, apágalos con `desired_counts`.
- Wompi, IA y Firebase reciben sus llaves por variables sensibles (`TF_VAR_wompi_private_key`,
  `TF_VAR_wompi_events_secret`, `TF_VAR_wompi_integrity_secret`, `TF_VAR_llm_api_key`,
  `TF_VAR_fcm_service_account_json`). Sin ellas: Wompi en modo prueba, IA con respuestas de ejemplo y push solo en bandeja.
- Registra en Wompi la salida `wompi_webhook_url`.
