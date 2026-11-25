# ADR 0002 · Motor de base de datos de cada servicio

- **Estado:** Aceptado
- **Fecha:** 2026-11-23
- **Responsables:** Carlos Piedrahita (redacción), equipo Desparcha2 (revisión en el PR)
- **Jira:** SCRUM-130
- **Relacionados:** ADR 0001 (despliegue en AWS Academy Learner Lab), `terraform/aws-lab/`, `docker-compose.yml`

## Contexto

Cada microservicio de Festa tiene **su propia base de datos**: no se comparten tablas ni hay permisos cruzados (ver `CLAUDE.md` y `contracts/README.md`). Este ADR deja por escrito qué motor usa cada servicio y por qué, para poder aprovisionar la infraestructura en local (Docker Compose) y en AWS (Terraform).

Restricciones que pesan en la decisión:

- **Piloto con pocos usuarios** (estudiantes de la ECI): el costo y la simplicidad pesan más que el rendimiento máximo.
- **AWS Academy Learner Lab** (ADR 0001):
  - RDS solo llega hasta tamaño medium;
  - **DocumentDB y Amazon MQ están bloqueados**;
  - no se pueden crear roles IAM.
- **Equipo pequeño:** pocos motores distintos = menos cosas que operar.

## Decisión

| Servicio | Motor | Base | Por qué |
|---|---|---|---|
| auth | PostgreSQL 16 | `auth_db` | Cuentas y refresh tokens: datos relacionales con unicidad estricta (email, sesión) y transacciones (rotación de tokens, outbox) |
| user | PostgreSQL 16 + Redis (db 2) | `user_db` | Perfiles, intereses, comercios, reportes y consentimientos: relaciones claras. Redis solo como caché de perfiles |
| event | PostgreSQL 16 **+ PostGIS** | `event_db` | Consultas geoespaciales del mapa (eventos dentro del área visible, distancia al usuario) con índices espaciales |
| booking | PostgreSQL 16 | `booking_db` | Asistencias y pases QR: el uso único del QR depende de un `UPDATE ... WHERE used_at IS NULL` atómico (RNF7) |
| payment | PostgreSQL 16 | `payment_db` | Órdenes y dinero: necesita transacciones ACID, retención de cupos sin sobreventa y trazabilidad |
| ai | MongoDB + Redis (db 1) | `ai_db` | Historial de chat y descripciones generadas: documentos de forma variable. Redis para el rate limit por usuario (RNF8) |
| notification | MongoDB | `notification_db` | Bandeja de avisos, tokens de dispositivo y preferencias: documentos por usuario, sin relaciones entre ellos |
| analytics | MongoDB | `analytics_db` | Contadores y agregados por evento y comercio: escrituras frecuentes de documentos que crecen (`$inc`), sin joins |

### ¿event_db usa PostGIS?

**Sí.** event-service filtra eventos por área visible y por distancia (RF5, RF6, Parches en Vivo), y PostGIS lo resuelve con índices espaciales (GiST) en la base, no en la aplicación. En AWS, RDS PostgreSQL 16 trae PostGIS como extensión (`CREATE EXTENSION postgis` en `db-init.sh`), así que no requiere otro servicio.

### Regla general

- **PostgreSQL** cuando hay dinero, unicidad, transacciones o relaciones (auth, user, event, booking, payment).
- **MongoDB** cuando el dato es un documento por usuario o por evento, sin joins y con forma que cambia (ai, notification, analytics).
- **Redis** solo como caché o contador efímero. Nunca es la fuente de verdad.

## Costo y compatibilidad en la nube (AWS Learner Lab)

| Pieza | Local (Compose) | AWS lab | Costo aproximado | Nota |
|---|---|---|---|---|
| PostgreSQL | `postgis/postgis:16-3.4`, una instancia | **RDS PostgreSQL 16 `db.t3.micro`**, una instancia con 5 bases | ~USD 13/mes encendido | Una sola instancia con una base y un usuario por servicio: aislamiento lógico sin pagar 5 instancias. Cifrado en reposo |
| MongoDB | `mongo:7.0` (o `4.4.29` en CPUs sin AVX) | **Contenedor en Fargate** con `/data/db` en **EFS** cifrado | ~USD 11/mes (0,25 vCPU, 1 GB) + EFS por GB | DocumentDB está bloqueado en el lab. En una cuenta normal se reemplaza por DocumentDB o MongoDB Atlas sin cambiar código (protocolo compatible) |
| Redis | `redis:7.4-alpine` | **ElastiCache `cache.t3.micro`**, un nodo | ~USD 12/mes | Un nodo sin cluster mode, para poder usar las bases lógicas 0, 1 y 2 |

Los costos son referencias de la región us-east-1 para 730 h al mes. En el lab el entorno se destruye al terminar cada sesión, así que el gasto real es una fracción.

## Alternativas descartadas

- **Todo en PostgreSQL** (con JSONB para ai, notification y analytics). Es viable y ahorraría operar Mongo. Se descartó porque el equipo de esos servicios ya trabaja con documentos y los contadores de analytics encajan mejor con `$inc`. Si operar Mongo en Fargate da problemas, es el plan B natural.
- **Una instancia de RDS por servicio.** Da el mejor aislamiento, pero cuesta 5 veces más y el lab limita los recursos. El aislamiento lógico (base + usuario por servicio, sin `GRANT` cruzados) es suficiente para el piloto.
- **DynamoDB para analytics.** Lo descartamos porque el equipo no lo conoce y exige diseñar las consultas por adelantado; no compensa para conteos simples.

## Consecuencias

- Hay **3 motores para operar** (PostgreSQL, MongoDB y Redis).
- Las migraciones son versionadas por servicio:
  - Flyway en Java;
  - `node-pg-migrate` en Node;
  - scripts numerados con la colección `_migrations` en Mongo.
- **Cambiar de motor en un servicio no afecta a los demás:** solo se comunican por eventos de RabbitMQ.

## Pendientes y hallazgos

- **La caché de Redis del mapa (RNF1) no está implementada.** El esquema reserva la base 0 de Redis para la caché del mapa en event-service, pero hoy event-service no usa Redis.
  - Cuando se agregue, no cambia este ADR.
  - Si las mediciones de SCRUM-78 muestran que el mapa ya responde en < 2 s sin caché, la base 0 se puede liberar.
- **Diagramas:** actualizar los de Lucid y los C4 para que coincidan con la tabla de decisión. Están fuera del repo.
