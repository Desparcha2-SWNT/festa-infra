#!/usr/bin/env bash
# Verifica que la infraestructura levantada con `docker compose up -d` quedó bien armada (SCRUM-44).
# Lo usa el CI, pero también sirve en local después de levantar el entorno:
#   ./scripts/ci-check.sh
# Comprueba una BD y un usuario por servicio, el aislamiento entre servicios, PostGIS,
# la contraseña de Redis y la topología de RabbitMQ cargada desde contracts/.
set -euo pipefail
cd "$(dirname "$0")/.."

env_get() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
FAILS=0
ok() { printf '  ✓ %s\n' "$1"; }
ko() { printf '  ✗ %s\n' "$1"; FAILS=$((FAILS + 1)); }
dc() { docker compose "$@"; }

# psql_as <usuario> <contraseña> <bd> <sql>: conexión por TCP para que se exija la contraseña.
psql_as() {
  dc exec -T -e PGPASSWORD="$2" postgres psql -h 127.0.0.1 -U "$1" -d "$3" -tAc "$4" 2>/dev/null
}
mongo_as() {
  dc exec -T mongo mongosh --quiet -u "$1" -p "$2" --authenticationDatabase "$3" "$3" --eval "$4" 2>/dev/null
}

echo "Postgres: una BD y un usuario por servicio"
for svc in auth user event booking payment; do
  pw=$(env_get "$(echo "$svc" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD")
  [ "$(psql_as "${svc}_svc" "$pw" "${svc}_db" 'select 1')" = 1 ] && ok "${svc}_svc entra a ${svc}_db" || ko "${svc}_svc no entra a ${svc}_db"
done
if psql_as auth_svc "$(env_get AUTH_DB_PASSWORD)" user_db 'select 1' >/dev/null; then
  ko "auth_svc entra a user_db (no hay aislamiento)"
else
  ok "auth_svc no puede entrar a user_db (aislamiento)"
fi
psql_as event_svc "$(env_get EVENT_DB_PASSWORD)" event_db 'select postgis_version()' | grep -q . \
  && ok "PostGIS disponible en event_db" || ko "PostGIS no está en event_db"

echo "Mongo: una BD y un usuario por servicio"
for svc in ai notification analytics; do
  pw=$(env_get "$(echo "$svc" | tr '[:lower:]' '[:upper:]')_MONGO_PASSWORD")
  [ "$(mongo_as "${svc}_svc" "$pw" "${svc}_db" 'db.runCommand({ping: 1}).ok')" = 1 ] && ok "${svc}_svc entra a ${svc}_db" || ko "${svc}_svc no entra a ${svc}_db"
done
if mongo_as ai_svc "$(env_get AI_MONGO_PASSWORD)" ai_db "db.getSiblingDB('analytics_db').ci.insertOne({a: 1})" >/dev/null; then
  ko "ai_svc escribe en analytics_db (no hay aislamiento)"
else
  ok "ai_svc no puede escribir en analytics_db (aislamiento)"
fi

echo "Redis"
[ "$(dc exec -T redis redis-cli --no-auth-warning -a "$(env_get REDIS_PASSWORD)" ping)" = PONG ] && ok "responde con contraseña" || ko "no responde con contraseña"
dc exec -T redis redis-cli ping 2>&1 | grep -q NOAUTH && ok "rechaza conexiones sin contraseña" || ko "acepta conexiones sin contraseña"

echo "RabbitMQ: topología cargada desde contracts/"
api() { curl -sf -u "$(env_get RABBITMQ_USER):$(env_get RABBITMQ_PASSWORD)" "http://localhost:15672/api/$1"; }
want_q=$(jq '.queues | length' contracts/rabbitmq/definitions.json)
want_x=$(jq '.exchanges | length' contracts/rabbitmq/definitions.json)
got_q=$(api queues | jq length)
got_x=$(api exchanges | jq '[.[] | select(.name | startswith("festa."))] | length')
[ "$got_q" = "$want_q" ] && ok "$got_q colas" || ko "colas: $got_q (esperadas $want_q)"
[ "$got_x" = "$want_x" ] && ok "$got_x exchanges festa.*" || ko "exchanges: $got_x (esperados $want_x)"

if [ "$FAILS" -gt 0 ]; then
  echo "FALLÓ: $FAILS verificaciones"
  exit 1
fi
echo "OK"
