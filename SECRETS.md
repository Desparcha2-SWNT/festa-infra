# Gestión de secretos (SCRUM-49)

Ningún secreto real vive en el código. Esto es lo que hay en cada etapa y por qué.

## 1. Desarrollo local

- `.env.example` es el **contrato**: lista todas las variables que existen, con valores de
  ejemplo (`change-me-*`, `prv_test_xxx`, etc.), y sí se versiona. Hoy, en `develop`, lo tienen los
  repos que ya tienen código con secretos propios: `festa-infra`, `festa-auth-service`,
  `festa-user-service` y `festa-event-service`. Los demás `festa-*-service` lo agregan con su código.
- `.env` es la copia con los valores reales de cada quien. Está en `.gitignore` en los repos que
  tienen `.env.example`, y nunca se sube.
- `./scripts/gen-secrets.sh` genera lo que no puede ser un valor fijo de ejemplo:
  - Las llaves JWT RS256 y el secreto de firma del QR quedan en `./secrets/`, ignorado por git.
  - `PII_ENCRYPTION_KEY` es la excepción: se escribe directo en `.env` (sustituye el valor vacío
    de la plantilla), no en `./secrets/` — ver `scripts/gen-secrets.sh`.
- `ANALYTICS_INBOX_RETRY_KEY` y `PAYMENT_INBOX_RETRY_KEY` firman el origen de los reintentos de la inbox de
  analytics y de payment (HMAC); cada servicio la lee como `INBOX_RETRY_KEY`. Con las
  credenciales de RabbitMQ compartidas, cualquiera puede publicar directo en una inbox; sin esta clave no puede
  fabricar un reintento válido. Es una clave **por servicio** y **todas las réplicas** de ese servicio deben usar
  la misma (si cada una generara la suya, rechazaría los reintentos firmados por otra). En local las genera
  `./scripts/gen-secrets.sh` (aleatorias y persistentes en `.env`; la plantilla `.env.example` las deja **vacías** a
  propósito, porque un valor de ejemplo sería una clave pública); en AWS la genera Terraform (`random_bytes`, estable mientras no cambie el estado) y llega como secreto de ECS.
  Rotarla pierde los reintentos que estén en vuelo (pasan a la DLQ); se redespliega con la nueva.
  - Compose exige que no esté vacía (`:?`) y el servicio se niega a arrancar con una clave vacía o de menos de 16
    caracteres: una clave conocida dejaría la firma sin efecto.
  - **Límites, para no sobrevalorarla:** en el Learner Lab todas las tareas usan `LabRole` y los secretos viven en un
    único secreto JSON, así que ECS solo inyecta la variable a analytics pero otra tarea comprometida podría leer
    la clave con las credenciales de su rol. Tampoco sustituye a los usuarios y permisos de RabbitMQ por servicio:
    hoy todos comparten el mismo usuario, y la firma solo impide fabricar un reintento sin conocer la clave. En
    una cuenta propia, el aislamiento real exige un rol de tarea por servicio con acceso solo a sus secretos.
- Verificado (2026-10-29): en el historial completo de los 12 repos no hay ningún `.env` real ni
  ningún archivo de `secrets/` commiteado — solo los `.env.example` con placeholders (hoy existen en festa-infra, festa-auth-service, festa-user-service y festa-event-service).

## 2. CI (GitHub Actions)

Los workflows de CI/CD de todos los repos solo usan el `GITHUB_TOKEN` que GitHub genera e invalida
automáticamente por ejecución (permisos explícitos por job, ver cada `ci.yml`/`cd.yml`). La única
excepción es el despliegue al laboratorio (`festa-infra/.github/workflows/deploy-lab.yml`), que
además lee las credenciales de sesión de AWS del environment `aws-lab` (ver § 4). Ningún workflow
usa hoy un secreto de larga duración:

- El token fino `FESTA_INFRA_TOKEN` que se usó mientras `festa-infra` era privado ya no hace falta
  (el repo es público desde que el equipo decidió abrir los 12 repos) y no quedó configurado como
  secreto en ningún repo — se verificó con `gh secret list`. Pendiente: quien lo creó debe
  revocarlo a mano en GitHub → Settings → Developer settings → Fine-grained tokens, ya que un PAT
  no se puede borrar por API.
- `festa-infra/scripts/ci-check.sh` y el CI de `festa-gateway` generan sus propios secretos
  desechables en cada corrida (`gen-secrets.sh`, llaves JWT de prueba) — nunca reutilizan nada de
  un entorno real.

## 3. Protecciones activas en GitHub (2026-10-29)

Se activó en los 12 repos de la organización (antes estaba apagado a pesar de ser gratis en
repos públicos):

- **Secret scanning**: alerta si alguien commitea un patrón reconocible de credencial.
- **Push protection**: bloquea el `push` antes de que el secreto llegue al historial, no solo
  después.
- **Dependabot alerts + security updates**: ya estaban activas las alertas; se activó además la
  apertura automática de PRs para las dependencias con vulnerabilidad conocida.

## 4. Producción (pendiente del laboratorio de AWS, SCRUM-134)

Hoy no hay ningún secreto de producción real (Wompi, Google OAuth, Firebase, la API del LLM) 
porque no hay ningún entorno desplegado. Cuando llegue el acceso a AWS:

- Los secretos reales van a AWS Secrets Manager (o Parameter Store en modo `SecureString`), nunca
  horneados en la imagen de Docker ni en variables de entorno del workflow.
- Los servicios los leen en el arranque desde el gestor de secretos del entorno, igual que hoy
  los leen desde `.env` en local.
- En el Learner Lab no se pueden crear roles IAM ni OIDC: solo existe `LabRole`. Mientras dure el laboratorio,
  el workflow usa las credenciales de sesión de `LabRole` guardadas como secretos de GitHub. Vencen cada ~4 h,
  así que hay que renovarlas en cada sesión. Es una excepción del laboratorio: en una cuenta propia se usaría
  OIDC con un rol de corta duración por ejecución.
- Rotación: las llaves JWT y `PII_ENCRYPTION_KEY` rotan regenerándolas y redesplegando; las de
  Wompi y Google OAuth rotan desde sus propias consolas.
