# Gestión de secretos (SCRUM-49)

Ningún secreto real vive en el código. Esto es lo que hay en cada etapa y por qué.

## 1. Desarrollo local

- `.env.example` (en este repo y en cada `festa-*-service`) es el **contrato**: lista todas las
  variables que existen, con valores de ejemplo (`change-me-*`, `prv_test_xxx`, etc.), y sí se
  versiona.
- `.env` es la copia con los valores reales de cada quien. Está en `.gitignore` en los 12 repos y
  nunca se sube.
- `./scripts/gen-secrets.sh` genera lo que no puede ser un valor fijo de ejemplo: las llaves JWT
  RS256, el secreto de firma del QR y `PII_ENCRYPTION_KEY`. Quedan en `./secrets/`, también
  ignorado por git.
- Verificado (2026-10-29): en el historial completo de los 12 repos no hay ningún `.env` real ni
  ningún archivo de `secrets/` commiteado — solo los `.env.example` con placeholders.

## 2. CI (GitHub Actions)

Los workflows de CI/CD de todos los repos solo usan el `GITHUB_TOKEN` que GitHub genera e invalida
automáticamente por ejecución (permisos explícitos por job, ver cada `ci.yml`/`cd.yml`). Ningún
workflow usa hoy un secreto de larga duración:

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
- GitHub Actions se autentica contra AWS con OIDC (un rol de IAM de corta duración por ejecución),
  no con una llave de acceso de AWS guardada como secreto de GitHub — así una fuga del repo nunca
  expone una credencial de larga duración.
- Rotación: las llaves JWT y `PII_ENCRYPTION_KEY` rotan regenerándolas y redesplegando; las de
  Wompi y Google OAuth rotan desde sus propias consolas.
