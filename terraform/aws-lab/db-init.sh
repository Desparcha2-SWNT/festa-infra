#!/bin/sh
# Crea en RDS una base y un usuario dueño por servicio, igual que postgres/init/01-create-databases.sh en el
# compose. Corre como tarea de ECS de una sola vez (imagen postgres:16-alpine) antes de los servicios.
# Es idempotente: se puede volver a correr y además actualiza las contraseñas si cambiaron.
#
# Diferencias con el compose, por ser RDS:
# - El usuario maestro no es superusuario. En PostgreSQL 16, para crear una base con OWNER <rol> tiene que
#   poder hacer SET ROLE a ese rol: por eso el GRANT <rol> TO CURRENT_USER.
# - La conexión va con SSL (RDS lo exige desde PostgreSQL 15).
set -eu
export PGSSLMODE=require PGCONNECT_TIMEOUT=10

# RDS puede tardar unos segundos más que el estado "available" en aceptar conexiones.
i=0
until psql -d postgres -c 'SELECT 1' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge 30 ] && { echo "db-init: no hay conexión con $PGHOST" >&2; exit 1; }
  sleep 5
done

create_db() {
  name="$1" pass="$2" extra="${3:-}"
  echo "db-init: ${name}_db / ${name}_svc"
  psql -v ON_ERROR_STOP=1 -d postgres -v role="${name}_svc" -v db="${name}_db" -v pass="$pass" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'role', :'pass') \gexec
SELECT format('GRANT %I TO CURRENT_USER', :'role') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
SQL
  psql -v ON_ERROR_STOP=1 -d "${name}_db" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto; ${extra}"
}

create_db auth    "$AUTH_DB_PASSWORD"
create_db user    "$USER_DB_PASSWORD"
create_db event   "$EVENT_DB_PASSWORD" "CREATE EXTENSION IF NOT EXISTS postgis;"
create_db booking "$BOOKING_DB_PASSWORD"
create_db payment "$PAYMENT_DB_PASSWORD"
echo "db-init: listo"
