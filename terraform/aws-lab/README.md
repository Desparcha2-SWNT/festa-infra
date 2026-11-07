# Despliegue en el AWS Academy Learner Lab

Terraform que levanta Festa en AWS (SCRUM-134, ADR 0001). Lo corre el workflow
[`Deploy AWS lab`](../../.github/workflows/deploy-lab.yml), o una persona desde su equipo.

## Qué crea

```
internet ──► ALB público :80 ──► Kong (festa-gateway) ──► NLB interno ──► auth :8081 · user :8082 · event :8083
                                                                     └──► RabbitMQ :5672
                    servicios ──► RDS PostgreSQL 16 (una base y un usuario por servicio)
                    user-service ──► ElastiCache Redis (db 2)
```

| Pieza | Servicio de AWS | Notas |
|---|---|---|
| Cómputo | ECS Fargate | Un servicio de ECS por microservicio, con las imágenes de GHCR |
| Entrada | ALB público (HTTP) | Solo llega a Kong. Kong ve la IP real del cliente (`X-Forwarded-For`) |
| Entre servicios | NLB interno | Un puerto por servicio. Reemplaza el DNS por nombre (ver restricciones) |
| PostgreSQL | RDS `db.t3.micro`, cifrado en reposo | `db-init.sh` crea las bases y usuarios, como `postgres/init` del compose |
| Redis | ElastiCache `cache.t3.micro` | Un nodo, sin modo clúster, para poder usar las bases 0, 1 y 2 |
| RabbitMQ | Tarea de Fargate | Carga la topología de `contracts/rabbitmq/definitions.json` al arrancar |
| Secretos | Secrets Manager | Llaves JWT, contraseñas y llave PII, generadas por Terraform |
| Logs | CloudWatch Logs `/ecs/festa-lab` | 3 días de retención |

## Restricciones del Learner Lab (verificadas el 7-nov-2026)

- **No hay Cloud Map** (`servicediscovery:*` da AccessDenied): ECS no resuelve `auth-service` por nombre. Por
  eso existe el NLB interno, y Kong recibe las URLs por variables de entorno (festa-gateway#5).
- **No hay Amazon MQ** (explicit deny): RabbitMQ corre como contenedor.
- **No se pueden crear roles IAM ni un proveedor OIDC**: todo usa `LabRole`, y GitHub Actions entra con las
  credenciales temporales de la sesión del lab.
- **RDS solo hasta tamaño medium** y solo las regiones us-east-1 y us-west-2.
- Las tareas usan las subredes públicas de la VPC por defecto con IP pública, para no pagar un NAT Gateway.
  Nada entra desde internet salvo al ALB: lo impiden los security groups.

## Desplegar

1. Enciende el lab y copia el bloque `[default]` de **AWS Details → AWS CLI**.
2. Guarda las credenciales en GitHub (vencen con la sesión, unas 4 horas):
   ```bash
   ./scripts/aws-lab/set-github-creds.sh     # pega el bloque y termina con Ctrl+D
   ```
3. En GitHub: **Actions → Deploy AWS lab → Run workflow**, con `apply`. El resumen muestra la URL de la API.
4. **Al terminar, corre el mismo workflow con `destroy`.** Los créditos se siguen gastando aunque se cierre la
   sesión del lab.

El primer despliegue tarda unos 15 minutos (RDS es lo más lento). Con `services_desired_count = 0` se levanta
solo la base, útil mientras no haya imágenes en GHCR.

### Desde un equipo

```bash
export AWS_REGION=us-east-1     # con las credenciales del lab en ~/.aws/credentials
BUCKET=$(../../scripts/aws-lab/bootstrap-state.sh)
terraform init -backend-config="bucket=$BUCKET" -backend-config="key=lab/terraform.tfstate" -backend-config="region=us-east-1"
terraform apply
terraform destroy
```

El estado vive en el bucket `festa-tfstate-<cuenta>`, con bloqueo (`use_lockfile`) y versionado. Así, el
workflow y cualquier persona del equipo trabajan sobre el mismo estado.

## Imágenes

Los servicios usan `ghcr.io/desparcha2-swnt/festa-<servicio>:<tag>`, que publica el CD de cada repo al fusionar
a `main`. Fargate las descarga sin credenciales, así que **los paquetes de GHCR tienen que ser públicos**
(Settings del paquete → Change visibility). Los repos ya son públicos, así que no se expone nada nuevo.

## Pendiente

- HTTPS: el ALB solo escucha HTTP porque no hay dominio para un certificado de ACM. Android bloquea el tráfico
  HTTP en los APK de release, así que hay que resolverlo antes de distribuir la app (CloudFront delante del
  ALB da HTTPS con su dominio por defecto).
- booking, payment, ai, notification y analytics: se agregan cuando existan sus imágenes.
