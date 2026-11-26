# ¿Por qué microservicios y no un monolito?

**Jira:** SCRUM-132 · **Para:** la sustentación (pregunta del profesor)
**Relacionados:** ADR 0001 (AWS Learner Lab), [ADR 0002 (bases de datos)](https://github.com/Desparcha2-SWNT/.github/blob/develop/docs/adr/0002-motores-de-base-de-datos.md), `stateless-contenedores-autoescalado.md`

## Respuesta corta

Para un piloto con pocos usuarios, **un monolito sería más barato y más simple**, y lo decimos sin rodeos. Elegimos microservicios por tres razones que sí pesan en Festa:

1. **Seis personas trabajando en paralelo sin pisarse:** cada quien es dueño de un servicio, con su repo, su CI y su base.
2. **Aislar las partes riesgosas:**
   - **pagos** maneja dinero y un webhook externo;
   - la **IA** depende de un proveedor externo lento y con costo por uso;
   - el **mapa** recibe la mayor parte del tráfico.

   Si la IA se cae o se pone lenta, comprar boletas y entrar con QR siguen funcionando.
3. **Escalar solo lo que crece:** el mapa y el escaneo de QR en la puerta tienen picos que el resto no tiene.

El costo de esa decisión lo pagamos en complejidad: mensajería asíncrona, contratos de eventos y 11 repos. Lo mitigamos con contratos validados automáticamente (`contracts/`), outbox, reintentos y observabilidad (Prometheus y Grafana).

## Comparación

| Criterio | Monolito | Microservicios (lo que hicimos) |
|---|---|---|
| **Costo fijo de infraestructura (piloto)** | Bajo: 1 contenedor (0,5 vCPU, 1 GB) con IPv4 pública + RDS + ALB + almacenamiento. Unos USD 54/mes | Unas 4 veces más: 11 tareas en Fargate (9 contenedores, RabbitMQ y Mongo; USD 127,76), IPv4 públicas (40,15), RDS (13,14), ElastiCache (12,41), ALB y NLB (32,85) y almacenamiento (4,20): **USD 230,51/mes** encendido 24/7 (us-east-1). Con tráfico e IA, USD 276,70 en la fase 1 ([modelo de costos](https://github.com/Desparcha2-SWNT/.github/blob/develop/docs/costos/modelo-costos.md)). En el lab se apaga al terminar cada sesión |
| **Complejidad de desarrollo** | Baja: llamadas a funciones, una transacción para todo | Alta: eventos asíncronos, consistencia eventual, contratos, idempotencia |
| **Complejidad de operación** | Un despliegue, un log | 9 despliegues, logs distribuidos (se compensa con `correlationId` y tableros) |
| **Escalar** | Todo o nada: para aguantar el mapa se replica también pagos e IA | Por servicio: event y booking hasta 3 réplicas, el resto hasta 2 |
| **Aislamiento de fallas** | Un error de memoria en la IA tumba los pagos | La falla queda en su servicio; los mensajes esperan en la cola y se reintentan |
| **Trabajo en paralelo** | Un repo, conflictos constantes de merge | Un repo por servicio; el contrato de eventos es el acuerdo entre equipos |
| **Tecnología** | Un solo lenguaje y una sola base | La herramienta adecuada por servicio: Java en auth y user, Node, Python para IA, PostGIS para el mapa, Mongo para documentos |
| **Riesgo para el piloto** | Bajo técnicamente | Mayor: más piezas que pueden fallar. Lo cubren las pruebas de punta a punta (`scripts/e2e/smoke.mjs`); las alertas están propuestas en festa-infra#24, para Docker Compose |

## Qué se pierde y qué se gana en un piloto con pocos usuarios

**Se pierde:**
- **Dinero y tiempo:** más infraestructura encendida y más tiempo montando mensajería, contratos y CI por repo.
- **Consistencia inmediata:** el conteo de asistentes del mapa se actualiza unos milisegundos después de confirmar, no en la misma transacción.
- **Simplicidad para depurar:** un flujo como la compra cruza payment → RabbitMQ → booking → event.

**Se gana:**
- **Una arquitectura que ya resolvió lo difícil:** contratos, idempotencia, reintentos y servicios sin estado. Crecer después no exige reescribir.
- **Fallas acotadas:** la IA y Wompi son externos y no controlamos su disponibilidad.
- **Autonomía del equipo:** cada integrante despliega su servicio sin coordinar un release único.

## Plan de crecimiento a 3 años

> **Supuestos de usuarios: propuesta para aprobar en el equipo.** Se basan en la población de la ECI (~6.000 estudiantes) y en una expansión gradual a otras universidades de Bogotá.

| | Año 1 · Piloto ECI | Año 2 · Universidades de Bogotá | Año 3 · Bogotá abierta |
|---|---|---|---|
| **Usuarios registrados** | 1.000 | 15.000 | 60.000 |
| **Activos al día** | 150 | 2.000 | 9.000 |
| **Pico (peticiones/s)** | ~5 | ~60 | ~250 (viernes en la noche) |
| **Comercios** | 20 | 200 | 1.000 |
| **Boletas al mes** | 500 | 8.000 | 40.000 |

### Año 1 · Piloto en la ECI
- **Infraestructura:** la de hoy. ECS Fargate con 1 réplica por servicio, RDS `db.t3.micro`, Mongo en Fargate y ElastiCache `t3.micro`.
- **Autoescalado:** listo pero con máximos bajos (2–3 réplicas).
- **Foco:** validar el producto (¿la gente encuentra planes en el mapa? ¿los comercios venden?) y medir con los tableros de Grafana.
- **Costo:** dentro de los créditos del Learner Lab solo si el entorno se apaga entre sesiones (USD 50 alcanzan para unas 158 horas encendido).

### Año 2 · Varias universidades
- **Salir del Learner Lab** a una cuenta de AWS normal: dominio propio, certificado ACM, Cloud Map y roles IAM.
- **Base de datos:**
  - RDS sube a `db.t3.medium`;
  - **payment pasa a su propia instancia de RDS**, por aislamiento y auditoría del dinero;
  - el resto sigue compartiendo instancia, con bases separadas.
- **Mongo:** pasa a **DocumentDB o MongoDB Atlas**, administrado, con respaldos.
- **RabbitMQ:** pasa a **Amazon MQ** con 2 nodos.
- **Rendimiento:**
  - caché de Redis del mapa en event-service (RNF1);
  - rate limit de Kong con `policy: redis` para que valga entre réplicas.
- **Disponibilidad:** mínimo 2 réplicas en gateway, auth, event y booking.

### Año 3 · Ciudad
- **RDS:** con réplicas de lectura para event (mapa y búsqueda) y Multi-AZ.
- **Imágenes:** CDN (CloudFront) para las de los eventos.
- **Analytics:** pasa a un almacén de análisis (por ejemplo, exportar eventos a S3 y consultar con Athena) si los paneles de comercio se vuelven pesados.
- **Separar servicios si su equipo lo justifica:** por ejemplo, la búsqueda puede salir de event-service a un motor de búsqueda.
- **Autoescalado:** con máximos de 6–10 réplicas en gateway, event y booking.

## Recomendación

**Seguir con microservicios**, porque ya están construidos y tienen pruebas automatizadas. En AWS solo se han desplegado gateway, auth, user y event (7 de noviembre, en un entorno que ya se destruyó); falta desplegar el resto. Para el piloto pagamos un sobrecosto conocido a cambio de un equipo que trabaja en paralelo, fallas aisladas y un camino de crecimiento sin reescritura.

### Qué señal nos haría cambiar de decisión

| Señal | Qué haríamos |
|---|---|
| Al final del año 1 hay < 300 usuarios activos al día y el equipo se reduce a 2–3 personas | **Consolidar** en un *monolito modular*: los mismos módulos y las mismas bases lógicas, un solo despliegue. Los contratos de eventos se vuelven llamadas internas. Es reversible porque los límites entre módulos ya están claros |
| Más del 30 % del tiempo del equipo se va en infraestructura y no en funciones | Fusionar los servicios más pequeños (por ejemplo notification + analytics) |
| Un servicio necesita más de 3 réplicas sostenidas o su equipo crece | **Separar más** ese servicio (búsqueda, chat de IA) |
| El costo mensual supera el presupuesto del año | Bajar mínimos a 0–1 fuera de horario, apagar servicios no críticos de noche |
