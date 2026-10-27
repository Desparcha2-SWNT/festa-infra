#!/bin/bash
# Crea una base de datos y un usuario dueño por servicio.
# Ningún usuario tiene permisos sobre la BD de otro servicio.
set -euo pipefail

create_db() {
  local name="$1" password="$2" extra="${3:-}"
  echo "Creando ${name}_db / ${name}_svc"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    CREATE ROLE ${name}_svc LOGIN PASSWORD '${password}';
    CREATE DATABASE ${name}_db OWNER ${name}_svc;
    REVOKE ALL ON DATABASE ${name}_db FROM PUBLIC;
SQL
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${name}_db" <<-SQL
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    ${extra}
SQL
}

create_db auth    "$AUTH_DB_PASSWORD"
create_db user    "$USER_DB_PASSWORD"
create_db event   "$EVENT_DB_PASSWORD" "CREATE EXTENSION IF NOT EXISTS postgis;"
create_db booking "$BOOKING_DB_PASSWORD"
create_db payment "$PAYMENT_DB_PASSWORD"
