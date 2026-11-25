# Servicios sin estado, contenedores y autoescalado

**Jira:** SCRUM-135 · **Para:** la sustentación (retroalimentación del profesor sobre contenedores y autoescalado)
**Relacionados:** ADR 0001 (AWS Learner Lab), [ADR 0002 (bases de datos)](https://github.com/Desparcha2-SWNT/.github/blob/develop/docs/adr/0002-motores-de-base-de-datos.md), `terraform/aws-lab/autoscaling.tf`

## 1. Qué significa que un servicio no tenga estado

Un servicio **sin estado** (stateless) no guarda nada importante en su propia memoria ni en su disco entre una petición y otra. Todo lo que debe sobrevivir vive **afuera**, en una base de datos, una caché o una cola. Consecuencias:

- **Cualquier réplica puede atender cualquier petición:** el balanceador no necesita "sesiones pegajosas".
- **Matar o reiniciar un contenedor no pierde datos:** lo que estaba en curso se reintenta (outbox, colas con reintento).
- **Escalar es agregar contenedores iguales:** no hay que copiar ni sincronizar nada entre ellos.

En Festa, la sesión del usuario tampoco vive en el servidor: viaja en el **JWT** que la app manda en cada petición. Cualquier réplica lo verifica con la llave pública, sin preguntarle a nadie.

## 2. Dónde vive el estado en Festa

| Estado | Dónde vive | Quién lo usa |
|---|---|---|
| Cuentas, perfiles, eventos, asistencias, pases QR, órdenes | **PostgreSQL** (RDS): una base por servicio | auth, user, event, booking, payment |
| Historial del chat, bandeja de avisos, agregados del panel | **MongoDB** (contenedor con disco en EFS) | ai, notification, analytics |
| Caché de perfiles y contadores de rate limit de la IA | **Redis** (ElastiCache) | user (db 2), ai (db 1) |
| Eventos entre servicios todavía no consumidos | **RabbitMQ** (colas durables) | todos |
| Eventos todavía no publicados | **Tabla `outbox`** en la base de cada servicio | productores |
| Sesión del usuario | **JWT** en el teléfono + refresh token (hash) en `auth_db` | auth, Kong, todos |
| Secretos (llaves JWT, contraseñas, llave PII) | **Secrets Manager** | todos, al arrancar |

**Sin estado** (se escalan horizontalmente): gateway (Kong) y los 8 microservicios.
**Con estado** (no se autoescalan; una sola réplica en el piloto): RabbitMQ y MongoDB en Fargate, más RDS y ElastiCache como servicios administrados.

### Detalles que hacen que las réplicas no se pisen

- **Outbox y trabajos programados** (expirar órdenes, parches y tokens):
  - en Postgres usan `FOR UPDATE SKIP LOCKED` o bloqueos de Postgres, así que dos réplicas nunca toman la misma fila;
  - en Mongo, los servicios "reclaman" el documento con un vencimiento, y si una réplica muere, otra lo retoma.
- **Consumidores de RabbitMQ:** varias réplicas leen de la misma cola `<servicio>.inbox` y RabbitMQ reparte los mensajes. Cada consumidor es idempotente por `eventId`, así que un mensaje repetido no causa efectos dobles.
- **Excepción consciente:** el rate limit de Kong cuenta en la memoria de cada réplica (`policy: local`). Con 3 réplicas del gateway, el límite efectivo puede llegar a ser 3 veces el configurado. Para el piloto es aceptable; si molesta, se cambia a `policy: redis` usando el ElastiCache que ya existe.

## 3. Contenedores

- **Una imagen por servicio:** cada repo tiene su `Dockerfile` y el CD publica la imagen en GHCR (`ghcr.io/desparcha2-swnt/festa-<servicio>`) al fusionar a `main`.
- **La misma imagen corre en todos lados:** en el portátil (Docker Compose, `festa-infra/docker-compose.yml`) y en AWS (ECS Fargate). Lo único que cambia son las variables de entorno y los secretos.
- **ECS Fargate:** AWS corre los contenedores sin que manejemos servidores. Cada microservicio es un *servicio de ECS* con un número de réplicas (tareas). Si una tarea falla su health check, ECS la reemplaza sola.
- **Recursos por tarea:** 0,25 vCPU y 0,5 GB para los servicios en Node y Python; 0,5 vCPU y 1 GB para los dos en Java (auth y user).

```
internet ─HTTPS─► API Gateway ─► ALB interno ─► Kong ×1..3 ─► NLB interno ─► servicios ×1..3
                                                                          │
                      ┌───────────────────────────────────────────────────┤
                      ▼                    ▼                   ▼          ▼
                RDS PostgreSQL       MongoDB (EFS)      ElastiCache    RabbitMQ
                 (con estado)        (con estado)       (con estado)  (con estado)
```

## 4. Política de autoescalado

> **Estado:** propuesta. Los números deben aprobarse en la revisión del PR o en la reunión del equipo. Están configurados en `terraform/aws-lab/autoscaling.tf` y se activan con `enable_autoscaling = true`.

| Parámetro | Valor | Por qué |
|---|---|---|
| Métrica | CPU promedio del servicio (`ECSServiceAverageCPUUtilization`) | Es la que ECS mide sin instalar nada. Los servicios son livianos y la CPU sube con las peticiones |
| Objetivo | **60 %** | Deja margen para absorber un pico mientras arranca la réplica nueva (~1 min en Node, ~3 min en Java) |
| Subir | Enfriamiento de **60 s** | Reaccionar rápido cuando muchos abren el mapa a la vez |
| Bajar | Enfriamiento de **300 s** | Evitar quitar y poner réplicas con picos cortos |

| Servicio | Mínimo | Máximo | Nota |
|---|---|---|---|
| gateway (Kong) | 1 | 3 | Todo el tráfico pasa por aquí |
| event | 1 | 3 | El mapa es lo más consultado (RNF1: < 2 s) |
| booking | 1 | 3 | Ráfagas al escanear QR en la entrada de un evento |
| auth, user, payment, notification, analytics | 1 | 2 | Tráfico bajo y parejo |
| ai | 1 | 2 | El límite real es el costo del LLM (RNF8), no la CPU |

**Disparo, en concreto:** si el promedio de CPU de event-service pasa de 60 %, ECS agrega una réplica (hasta 3). Cuando baja de 60 % por 5 minutos, quita réplicas (hasta 1).

**Al volver a aplicar Terraform:** cada `terraform apply` devuelve las réplicas al número configurado (`desired_count`) y el autoescalado las ajusta de nuevo. No se usa `ignore_changes` porque entonces `services_desired_count` dejaría de poder subir o bajar el entorno.

**Por qué el mínimo es 1 y no 2:** en el piloto el tráfico es bajo y el lab cobra por tarea encendida. Si un contenedor muere, ECS lo reemplaza en 1 a 3 minutos. En producción el mínimo sería 2 por servicio crítico (gateway, auth, event, booking), para no tener caídas durante ese reemplazo.

### Cómo mostrarlo en la sustentación

1. Desplegar con `terraform apply -var enable_autoscaling=true`. El workflow **Deploy AWS lab** todavía no tiene esa opción.
2. Mostrar en la consola de ECS → servicio `event` → pestaña **Auto Scaling** la política creada (captura de pantalla).
3. Opcional, demo en vivo: generar carga contra el mapa (por ejemplo `npx autocannon -c 50 -d 300 <API>/api/events/clusters?...` con un token) y ver en ECS cómo `desired count` pasa de 1 a 2 o 3. Las métricas de CPU del servicio en la consola de ECS muestran la subida. Grafana (festa-infra#24) corre solo en Docker Compose, no en AWS.

Si el Learner Lab no permite crear el rol vinculado de Application Auto Scaling, el apply falla en esos recursos. En ese caso se muestra el archivo `autoscaling.tf` y se explica la política.

## 5. QR sin conexión (caché local)

En la entrada de un evento puede no haber señal. El diseño:

1. **Al comprar o confirmar asistencia**, la app descarga el pase. El QR contiene un token firmado con HMAC por booking-service (id del pase + evento) y **no tiene datos personales**.
2. **Guardado local:** la app guarda ese token en el almacenamiento cifrado del teléfono (`flutter_secure_storage`), junto con el nombre y la fecha del evento.
3. **En la puerta, sin datos:** la pantalla "Mis entradas" dibuja el QR desde el almacenamiento local, sin llamar al servidor.
4. **Quien escanea sí necesita conexión.** El organizador valida contra booking-service, que verifica la firma y marca el pase como usado de forma atómica (RNF7: un solo uso).
5. **Pase revocado:** si el evento se cancela o la boleta se reembolsa, el pase guardado en el teléfono deja de servir, porque el servidor lo rechaza al escanear (`revoked`). La app lo marca como inválido la próxima vez que tenga conexión.

**Estado actual (25 de noviembre):** "Mis entradas" ya está en `develop` de festa-mobile (SCRUM-90, #32). La copia sin conexión (SCRUM-91) está en revisión en festa-mobile#41: es por cuenta, se refresca al volver a la app y se borra al cerrar sesión.

## 6. Pendiente fuera del repo

- **Diagramas de Lucid:** mostrar los servicios sin estado con sus réplicas (×1..3), el clúster de ECS Fargate y los componentes con estado aparte, como en el esquema de la sección 3.
- **Aprobar los números** de la sección 4.
