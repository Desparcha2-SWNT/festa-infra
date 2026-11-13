# festa-infra

Infraestructura local de Festa (Docker Compose) y **contratos de mensajería** de RabbitMQ (`contracts/`, única fuente de verdad).

## Qué levanta

| Servicio | Puerto | Notas |
|---|---|---|
| Postgres 16 + PostGIS | 5432 | Una BD + un usuario por servicio: `auth_db`, `user_db`, `event_db` (PostGIS), `booking_db`, `payment_db` |
| Mongo 7 | 27017 | `ai_db`, `notification_db`, `analytics_db` |
| Redis 7 | 6379 | Cache del mapa (db 0), rate limit de IA (db 1) y cache de perfiles de user-service (db 2) |
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

## Prueba de punta a punta

Con todo arriba y `PAYMENTS_ALLOW_SIMULATION=true` en `.env` (solo desarrollo), este script recorre el MVP completo a
través de Kong, como la app: registro (RF1), perfil y consentimiento (RF2/RNF5), verificación del comercio (RF3),
descripción con IA (RF9), evento con boletería y Parche en Vivo (RF4/RF19), mapa y búsqueda (RF5/RF6), chat de
recomendaciones (RF8), asistencia (RF7), compra con comisión (RF11), QR de un solo uso (RF10), notificaciones (RF12),
panel del comercio (RF15) y moderación (RF14).

```bash
docker compose --profile all up -d --build
node scripts/e2e/smoke.mjs        # GATEWAY_URL=http://localhost:8000 por defecto
```

Sin `LLM_API_KEY`, ai-service usa respuestas locales de ejemplo; sin la cuenta de servicio de Firebase, notification
deja los avisos solo en la bandeja de la app.

## Secretos

Ver [SECRETS.md](SECRETS.md): qué pasa con cada secreto en local, en CI y cuando haya un entorno
real desplegado.

## Contratos

Ver [contracts/README.md](contracts/README.md). Validar después de cualquier cambio:

```bash
cd contracts && npm install && npm run validate
```
