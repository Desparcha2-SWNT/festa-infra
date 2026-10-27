# festa-infra

Infraestructura local de Festa (Docker Compose) y **contratos de mensajería** de RabbitMQ (`contracts/`, única fuente de verdad).

## Qué levanta

| Servicio | Puerto | Notas |
|---|---|---|
| Postgres 16 + PostGIS | 5432 | Una BD + un usuario por servicio: `auth_db`, `user_db`, `event_db` (PostGIS), `booking_db`, `payment_db` |
| Mongo 7 | 27017 | `ai_db`, `notification_db`, `analytics_db` |
| Redis 7 | 6379 | Cache del mapa (db 0) y rate limit de IA (db 1) |
| RabbitMQ 3.13 | 5672 / UI 15672 | Topología cargada desde `contracts/rabbitmq/definitions.json` |
| Prometheus | 9090 | Scrapea `/metrics` de todos los servicios, Kong y RabbitMQ |
| Grafana | 3000 | Datasource Prometheus ya provisionado |
| Kong (gateway) | 8000 / 8443 | perfil `gateway` |
| Servicios 8081–8088 | — | un perfil por servicio, o `all` |
| cloudflared | — | perfil `tunnel`: URL pública para el webhook de Wompi |

## Arranque

```bash
cp .env.example .env          # edita contraseñas
./scripts/gen-secrets.sh      # llaves JWT, secreto de QR, PII_ENCRYPTION_KEY
docker compose up -d          # solo infraestructura
docker compose --profile auth --profile gateway up -d --build
docker compose --profile all up -d --build
```

Los servicios se construyen desde las carpetas hermanas (`../festa-<servicio>`), así que hay que clonar todos los repos en el mismo directorio padre.

Los scripts de `postgres/init` y `mongo/init` solo corren con el volumen vacío. Para recrear: `docker compose down -v`.

## Contratos

Ver [contracts/README.md](contracts/README.md). Validar después de cualquier cambio:

```bash
cd contracts && npm install && npm run validate
```
