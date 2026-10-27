#!/bin/bash
# Crea una base de datos y un usuario por servicio (solo readWrite sobre la suya).
# Funciona con mongosh (Mongo >= 5) y con el shell legado `mongo` (Mongo 4.4, CPUs sin AVX).
set -euo pipefail
SHELL_BIN=$(command -v mongosh || command -v mongo)

create_user() {
  local db="$1" user="$2" pwd="$3"
  echo "Creando ${db} / ${user}"
  "$SHELL_BIN" --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin "$db" \
    --eval "db.createUser({user: '${user}', pwd: '${pwd}', roles: [{role: 'readWrite', db: '${db}'}]})"
}

create_user ai_db           ai_svc           "$AI_MONGO_PASSWORD"
create_user notification_db notification_svc "$NOTIFICATION_MONGO_PASSWORD"
create_user analytics_db    analytics_svc    "$ANALYTICS_MONGO_PASSWORD"
