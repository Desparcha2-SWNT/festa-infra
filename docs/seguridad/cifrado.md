# Cifrado en tránsito y en reposo

**Jira:** SCRUM-48 (historia SCRUM-16) · **Requisito:** RNF4: TLS y datos personales cifrados en reposo (AES-256)

## Resumen

| Capa | Local (Docker Compose) | AWS lab (Terraform) |
|---|---|---|
| **App → gateway (HTTPS)** | Kong en `:8443`, **solo TLS 1.3** (`KONG_SSL_CIPHER_SUITE=modern`), certificado autofirmado | **API Gateway** termina TLS con certificado de AWS. Política `TLS_1_2`: acepta TLS 1.2 y 1.3, rechaza 1.0 y 1.1. Ver "TLS 1.3 en AWS" |
| **Dentro de la red** (gateway → servicios → RabbitMQ) | HTTP y AMQP sin TLS dentro de la red de Docker | HTTP dentro de la VPC: balanceadores internos sin IP pública, más security groups |
| **Servicios → PostgreSQL** | Sin TLS (misma máquina) | **TLS obligatorio:** RDS PostgreSQL 16 trae `rds.force_ssl=1`; Node usa `sslmode=no-verify` y Java `sslmode=require` |
| **Servicios → Redis** | Sin TLS (misma máquina) | **TLS obligatorio:** ElastiCache `transit_encryption_enabled = true`; user usa `SPRING_DATA_REDIS_SSL_ENABLED=true` y ai `rediss://` |
| **PostgreSQL en reposo** | Volumen de Docker sin cifrar (portátil de desarrollo) | **RDS `storage_encrypted = true`**: AES-256 con llave administrada por AWS (KMS) |
| **MongoDB en reposo** | Volumen de Docker sin cifrar | **EFS `encrypted = true`** (AES-256) y TLS en el montaje (`transit_encryption = "ENABLED"`) |
| **Redis en reposo** | Sin cifrar (solo caché) | **ElastiCache `at_rest_encryption_enabled = true`** (AES-256). Agregado en SCRUM-48 |
| **Secretos** (llaves JWT, contraseñas, llave PII) | `./secrets` y `.env`, ignorados por git | **Secrets Manager**, cifrado con KMS |
| **Estado de Terraform** | — | Bucket S3 con `encrypt = true` |
| **Datos personales en la aplicación** | **AES-256-GCM** con `PII_ENCRYPTION_KEY` (ver abajo) | Igual, con la llave en Secrets Manager |

## Datos personales cifrados por la aplicación (AES-256-GCM)

Además del cifrado del disco, los campos personales se cifran **antes** de llegar a la base. Así, quien vea una copia de la base o un volcado no lee correos ni nombres.

| Servicio | Qué cifra | Cómo |
|---|---|---|
| auth | email y nombre | `PiiCrypto`: AES-256-GCM con IV aleatorio, más un índice ciego HMAC-SHA256 para buscar por email |
| user | datos del perfil y del comercio | `AesGcmPiiEncryptor` |

**Excepciones justificadas:**

| Servicio | Dato | Por qué no se cifra en la app | Cómo se protege |
|---|---|---|---|
| notification | Última ubicación del usuario | Se busca con consultas geográficas de Mongo (`$centerSphere`), que no funcionan sobre datos cifrados | Solo con consentimiento (RNF5). A las 72 h deja de usarse para los avisos, pero se conserva hasta que se revoca el consentimiento o se borra la cuenta; no hay borrado automático. EFS cifrado en AWS |
| booking | Nombre para mostrar del asistente | Lo ve el organizador en la lista de asistentes; solo id y nombre, sin correo (`account.display_name_set`) | Base cifrada en RDS; se borra con `account.deleted` |
| ai | Historial del chat | El usuario puede escribir cualquier cosa | EFS cifrado; el usuario lo borra con `DELETE /api/ai/chat/history` |

## TLS 1.3 en AWS

En el lab el HTTPS público lo da **API Gateway (HTTP API)**, porque no hay dominio propio ni CloudFront (ADR 0001). Para los HTTP API, AWS aplica la política `TLS_1_2` y no deja cambiarla. Según la página de la política, esa política **acepta TLS 1.2 y TLS 1.3** y negocia 1.3 con clientes modernos (Android 10 o superior), pero la página de cifrado de datos de AWS dice que los HTTP API solo soportan TLS 1.2. Hay que confirmarlo con el endpoint real.

**Comprobarlo** cuando el lab esté arriba (`api_base_url` sale en el resumen del workflow):

```bash
HOST=<id>.execute-api.us-east-1.amazonaws.com
echo | openssl s_client -connect $HOST:443 -tls1_3 2>/dev/null | grep -E "^New,"   # esperado: TLSv1.3
echo | openssl s_client -connect $HOST:443 -tls1_1 2>/dev/null | grep -E "^New,"   # esperado: rechazado
```

**Si el curso exige TLS 1.3 exclusivo también en AWS:** hay que pasar API Gateway de HTTP API a **REST API** con política `SecurityPolicy_TLS13_1_3_2025_09`, o usar un dominio propio. Las dos opciones cambian `apigw.tf` y la segunda no está disponible en el Learner Lab. En local, Kong ya exige TLS 1.3 exclusivo.

## Cómo se verificó

- **Local:** `festa-gateway/scripts/smoke.sh` comprueba que `:8443` negocia TLS 1.3 y rechaza TLS 1.2.
- **Terraform:** `terraform validate`. El cambio de Redis reemplaza el recurso, así que en el próximo `apply` ElastiCache se recrea vacío. Es aceptable porque Redis solo guarda caché y contadores.

## Referencias

- [Security policy for HTTP APIs in API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-ciphers.html)
- [Data encryption in Amazon API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/data-protection-encryption.html)
