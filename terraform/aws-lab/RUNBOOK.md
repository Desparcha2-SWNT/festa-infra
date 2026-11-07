# Runbook: volver a desplegar Festa en el Learner Lab

Guía paso a paso para levantar el entorno otro día, más todos los errores que salieron en el primer despliegue
(7-nov-2026) con su causa y su solución. Qué crea el Terraform y por qué está armado así: [README.md](README.md).

## Resumen del 7-nov-2026

- Se desplegaron **gateway, auth, user y event** en ECS Fargate, con RabbitMQ, RDS PostgreSQL 16 y ElastiCache
  Redis. La entrada fue HTTPS por API Gateway.
- Se probó de punta a punta: registro, login, `account.registered` por RabbitMQ (user-service creó el perfil),
  intereses, y crear y leer un evento con PostGIS.
- Al final se corrió el workflow con `destroy`, pero **la sesión del lab terminó a mitad** (error 28). Borró los
  servicios, API Gateway, el ALB y Redis. **Quedaron RDS, el NLB interno, el clúster de ECS, el secreto, los
  security groups y los logs**, y el estado de Terraform quedó **bloqueado**.
- **Antes de cualquier otra cosa en la próxima sesión: hacer el paso 0** (terminar el destroy).
- El bucket del estado (`festa-tfstate-<cuenta>`) no se borra a propósito.

## 0. Terminar el destroy del 7-nov-2026 (una sola vez)

1. Enciende el lab y carga las credenciales (paso 1 de abajo).
2. Desde un equipo, en `terraform/aws-lab`, con las credenciales del lab:
   ```bash
   BUCKET=$(bash ../../scripts/aws-lab/bootstrap-state.sh)
   terraform init -backend-config="bucket=$BUCKET" -backend-config="key=lab/terraform.tfstate" -backend-config="region=us-east-1"
   # El bloqueo quedó colgado: el archivo de bloqueo es lab/terraform.tfstate.tflock en el bucket.
   aws s3 rm "s3://$BUCKET/lab/terraform.tfstate.tflock"
   terraform destroy
   ```
   `destroy` primero refresca: lo que ya no existe en AWS sale del estado sin error, y borra lo que quedó.
3. Si algún recurso ya no existe y `destroy` falla por eso: `terraform state rm '<recurso>'` y repite.
4. Comprueba en la consola de AWS que no queden RDS (`festa-lab`), balanceadores ni el clúster `festa-lab`.

| Servicio | Imagen probada | Repo |
|---|---|---|
| gateway | `sha-06b8155` | festa-gateway (`main`) |
| auth | `sha-d62bf67` | festa-auth-service (`main`) |
| user | `sha-d6c8bd8` | festa-user-service (`main`) |
| event | `sha-f0758c0` | festa-event-service (`main`) |

`latest` apuntaba a esas mismas imágenes. Si hubo fusiones a `main` después, `latest` trae lo nuevo.

## Volver a desplegar (unos 15 minutos)

### 1. Encender el lab y cargar las credenciales
1. En AWS Academy: **Start Lab**, espera el círculo verde y abre **AWS Details → AWS CLI**.
2. Desde la carpeta de festa-infra:
   ```bash
   ./scripts/aws-lab/set-github-creds.sh     # pega el bloque [default] y termina con Ctrl+D
   ```
   El script comprueba las credenciales y las guarda en el environment `aws-lab` de GitHub. **Vencen con la
   sesión del lab (unas 4 horas)**: si el workflow dice "credenciales vencieron", repite este paso.

### 2. Comprobar que las imágenes existen y son públicas
Fargate descarga de GHCR sin credenciales. Si un paquete es privado, la tarea no arranca.
```bash
for img in festa-gateway festa-auth-service festa-user-service festa-event-service; do
  tok=$(curl -s "https://ghcr.io/token?scope=repository:desparcha2-swnt/$img:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  echo "$img -> $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json' \
    https://ghcr.io/v2/desparcha2-swnt/$img/manifests/latest)"
done
```
Tiene que dar **200** en todas. Un 403 significa que el paquete es privado o no existe (ver errores 10 y 12).

### 3. Desplegar
**Actions → Deploy AWS lab → Run workflow**, rama `develop`:
1. Primero `plan`, y revisa el plan.
2. Luego `apply`, con `image_tag = latest` y `services_desired_count = 1`.

El resumen del run muestra la URL (`https://<id>.execute-api.us-east-1.amazonaws.com`). **La URL cambia en cada
despliegue nuevo.**

Desde un equipo, con las credenciales en `~/.aws/credentials`:
```bash
cd terraform/aws-lab
BUCKET=$(bash ../../scripts/aws-lab/bootstrap-state.sh)
terraform init -backend-config="bucket=$BUCKET" -backend-config="key=lab/terraform.tfstate" -backend-config="region=us-east-1"
terraform apply -var services_desired_count=1
```
Para levantar solo algunos servicios: `-var 'desired_counts={auth=1,gateway=1,user=0,event=0}'`. Para fijar
imágenes: `-var 'image_tags={auth="sha-d62bf67"}'`.

### 4. Verificar
Espera 1 o 2 minutos después del `apply`, porque Kong tarda en registrarse en el ALB (error 16).
```bash
API=https://<id>.execute-api.us-east-1.amazonaws.com
curl -s -o /dev/null -w '%{http_code}\n' $API/api/auth/me                 # 401: Kong pide JWT
curl -s -X POST $API/api/auth/register -H 'content-type: application/json' \
  -d '{"email":"prueba@escuelaing.edu.co","password":"Festa2026!x","displayName":"Prueba","accountType":"user","acceptedPrivacyPolicy":true}'
# con el accessToken que devuelve:
curl -s $API/api/auth/me  -H "Authorization: Bearer $TOK"                  # 200: auth + RDS
curl -s $API/api/users/me -H "Authorization: Bearer $TOK"                  # 200: perfil creado por account.registered
```

### 5. Apagar al terminar (obligatorio, y sin cerrar el lab antes de tiempo)
**Actions → Deploy AWS lab → Run workflow → `destroy`.** Los créditos se siguen gastando aunque se cierre la
sesión del lab. Todo prendido costaba unos **USD 0,17 por hora**. **No cierres el lab hasta que el run termine en verde** (error 28).

## Errores encontrados y su solución

### Restricciones del Learner Lab

| # | Síntoma | Causa | Solución |
|---|---|---|---|
| 1 | `mq:CreateBroker` → explicit deny | El lab no permite **Amazon MQ** | RabbitMQ como tarea de Fargate, con un contenedor auxiliar que hace `POST /api/definitions` con `contracts/rabbitmq/definitions.json` (`ecs.tf`) |
| 2 | El motor `docdb` da deny en RDS | El lab no permite **DocumentDB** | MongoDB irá como contenedor en Fargate (ai, notification y analytics, Sprint 3) |
| 3 | `servicediscovery:CreateHttpNamespace` → AccessDenied | No hay **Cloud Map**, así que ECS no resuelve `auth-service` por nombre | **NLB interno** con un puerto por servicio. Kong recibe las URLs por variables (`AUTH_SERVICE_URL`, etc., festa-gateway#5) |
| 4 | `iam:CreateRole` / `CreateOpenIDConnectProvider` → deny | No se pueden crear roles IAM ni OIDC | Todo usa **`LabRole`** (`data "aws_iam_role"`). GitHub entra con las credenciales temporales del lab |
| 5 | `db.r5.large` → explicit deny | RDS solo hasta tamaño **medium** | `db.t3.micro` |
| 6 | `cloudfront:*` → AccessDenied | No hay **CloudFront**, y sin dominio no hay certificado de ACM | **API Gateway HTTP API** + VPC Link a un ALB interno, con certificado de AWS (festa-infra#11) |
| — | Región sa-east-1 bloqueada | El lab solo permite us-east-1 y us-west-2 | us-east-1 |

### Errores al desplegar

| # | Síntoma | Causa | Solución |
|---|---|---|---|
| 7 | RabbitMQ no arranca: `Error when reading /var/lib/rabbitmq/.erlang.cookie: eacces` | El health check `rabbitmq-diagnostics` corre como root y crea la cookie antes que el servidor | Health check sin la CLI de Erlang: `nc -z 127.0.0.1 5672 && wget -qO /dev/null http://127.0.0.1:15672/` |
| 8 | auth-service no arranca: `algid parse error, not a sequence` | `tls_private_key.private_key_pem` es PKCS#1, y auth lee **PKCS#8** | `private_key_pem_pkcs8` (festa-infra#10) |
| 9 | Un secreto cambia pero los contenedores siguen con el valor viejo | ECS lee Secrets Manager solo al arrancar la tarea | `force_new_deployment` + `triggers` con la versión del secreto (festa-infra#10) |
| 10 | Descarga anónima de GHCR → 403; "Public" deshabilitado en el paquete | Política de la organización: no permitía paquetes públicos | Admin: `github.com/organizations/Desparcha2-SWNT/settings/packages` → marcar **Public**. Después, en cada paquete: *Change visibility → Public* |
| 11 | En AWS, Kong no encuentra los servicios | La imagen del gateway se publicó **antes** de festa-gateway#5 | Volver a pasar el gateway a `main` (festa-gateway#6). Regla: un cambio llega a AWS solo después de `develop → main`, cuando el CD publica la imagen |
| 12 | No hay imágenes en GHCR | El CD solo publica en un **push a `main`** | PR `develop → main` en cada servicio, con **"Create a merge commit"** (no squash, o `main` y `develop` divergen) |
| 13 | ECS reintenta para siempre un servicio cuya imagen no existe | `services_desired_count` aplica a todos | `desired_counts` por servicio (festa-infra#10) |
| 14 | Kong ve la IP del ALB o del VPC Link, no la del cliente, y el rate limit por IP lo comparten todos | Detrás del ALB, `KONG_TRUSTED_IPS`; detrás de API Gateway, la IP no llega en `X-Forwarded-For` | API Gateway sobrescribe `X-Real-IP` con `$context.identity.sourceIp`; Kong: `KONG_REAL_IP_HEADER=X-Real-IP`, `KONG_TRUSTED_IPS=<CIDR VPC>` (no se puede falsificar) |
| 15 | event-service: `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` | Express no confiaba en el proxy (Kong), y el límite por IP era compartido | `app.set('trust proxy', TRUST_PROXY)`, por defecto 1 (festa-event-service#5) |
| 16 | 503 tras 9 s en el primer minuto después de crear el ALB | Kong todavía se estaba registrando en el target group nuevo | Esperar 1 o 2 minutos. Es transitorio |
| 17 | RDS: crear la base con `OWNER` falla; Node no conecta | PostgreSQL 16 exige poder hacer `SET ROLE` al dueño; RDS exige SSL desde PG 15 | `GRANT <rol> TO CURRENT_USER` en `db-init.sh`, `PGSSLMODE=require`; event-service con `?sslmode=no-verify` |
| 18 | ElastiCache con contraseña no funciona con los clientes de hoy | AUTH en ElastiCache exige TLS en tránsito | Sin AUTH, aislado por security group a las tareas |
| 19 | Límite de descargas anónimas de Docker Hub desde AWS | Las IPs de AWS comparten el límite | Imágenes de Docker Hub desde **ECR Public** (`public.ecr.aws/docker/library/...`) |

### Errores del pipeline (GitHub Actions)

| # | Síntoma | Causa | Solución |
|---|---|---|---|
| 20 | `terraform init`: *The value cannot be empty* (backend S3) | Los scripts se subieron desde Windows **sin bit de ejecución**: `./bootstrap-state.sh` → *Permission denied*, escondido dentro de un `echo` | `git update-index --chmod=+x`, llamar con `bash` y validar que el bucket no esté vacío (festa-infra#12) |
| 21 | *Unable to process file command 'output'… "BucketArn"* | `aws s3api head-bucket` imprime JSON en stdout cuando el bucket existe | `head-bucket … >/dev/null 2>&1` (festa-infra#13) |
| 22 | Trivy marca el ALB público, HTTP sin TLS y la salida a internet | Configuración del lab | Corregido: `drop_invalid_header_fields`, salida del ALB solo a Kong y ALB interno. Excepciones justificadas en el código: HTTP dentro de la VPC (el TLS termina en API Gateway) y salida a internet de las tareas (no hay NAT) |
| 23 | "Protected branches only" deja desplegar cualquier rama | Esa opción solo ve reglas de protección clásicas, y el repo usa un *ruleset* | Environment `aws-lab` → **Selected branches**: `develop` y `main` |
| 24 | `Build y pruebas` falla en repos sin `package.json` o `pom.xml` | El CI reutilizable (`.github` #10) exige un stack | `stack: none` en el `ci.yml` de cada repo |
| 25 | `main` de auth bloqueado por CodeQL (CSRF) | La alerta es nueva contra `main`, y la regla exige resolver las conversaciones | Alerta descartada como *Won't fix* con justificación: auth es stateless y sin cookies (festa-auth-service#7) |

### Desde un equipo con Windows (Git Bash)

| # | Síntoma | Solución |
|---|---|---|
| 26 | `aws` no encuentra credenciales o `terraform` no encuentra el plan | No usar `MSYS_NO_PATHCONV=1` con rutas `/c/...`: `aws.exe` y `terraform.exe` necesitan rutas de Windows (`C:\...`) |
| 27 | `local-exec` corre otro bash | `interpreter = ["bash"]` y correr Terraform desde Git Bash, para que use su `bash` y no el de WSL |

### Al apagar

| # | Síntoma | Causa | Solución |
|---|---|---|---|
| 28 | `destroy` falla a mitad: `explicit deny … policy/voc-cancel-cred`, *Failed to save state* y *Error releasing the state lock* | La **sesión del lab terminó** (End Lab o venció) mientras corría `destroy`: el lab revoca las credenciales al instante | **No cerrar el lab hasta que el workflow termine en verde.** El `destroy` completo tarda unos 10-15 minutos (RDS es lo más lento), así que debe quedar al menos media hora de sesión. Si pasa: paso 0 de arriba (borrar `lab/terraform.tfstate.tflock` y repetir `destroy`) |

## Antes de distribuir el APK

- **La URL de la API cambia** en cada despliegue nuevo. Hay que crear o actualizar la variable de repo `API_BASE_URL`
  de festa-mobile con `terraform output -raw api_base_url`. El CD de mobile falla a propósito si no existe.
- mobile todavía no se ha pasado a `main`, así que nunca se ha publicado un APK.
- API Gateway corta las peticiones a los **30 s**: ai-service (Sprint 3) tiene que responder antes o usar streaming.

## Pendiente

- El workflow acepta un solo `image_tag` para todos los servicios. Podría aceptar uno por servicio, como `desired_counts`.
- Medir un redespliegue completo desde cero con los servicios (la base sola tardó unos 6 minutos).
- booking, payment, ai, notification y analytics: se agregan cuando tengan imagen.
