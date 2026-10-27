# Contratos de mensajería de Festa

**Única fuente de verdad** de la comunicación asíncrona entre servicios. Si un servicio necesita publicar o consumir algo nuevo, primero se cambia aquí (esquema + `rabbitmq/definitions.json`) y se corre `npm run validate`.

```
contracts/
├── envelope.schema.json                         # sobre común de todos los mensajes
├── events/<dominio>/<routing-key>.schema.json   # esquema de `data` + metadatos x-*
├── rabbitmq/definitions.json                    # exchanges, colas (inbox/retry/dlq) y bindings
└── scripts/validate.mjs                         # chequea ejemplos, dueños y topología == esquemas
```

Cada esquema trae:
- `x-exchange` y `x-routing-key`;
- `x-producer`, que siempre es el dueño del dominio;
- `x-version`;
- `x-consumers`, con el formato `{servicio: para qué lo consume}`;
- un ejemplo válido en `examples`. Úsalo en los tests.

## Reglas

### Topología
- **Un exchange `topic` por dominio**: `festa.auth`, `festa.user`, `festa.event`, `festa.booking`, `festa.payment`, `festa.ai`, `festa.notification`. Cada servicio publica **solo** en el suyo.
- **Routing key = `eventType`** = `<agregado>.<verbo_en_pasado>`, p. ej. `event.published`.
- **Tres colas por servicio consumidor:**

  | Cola | Para qué |
  |---|---|
  | `<servicio>.inbox` | Recibe todo lo que el servicio consume. |
  | `<servicio>.inbox.retry` | Espera 10 s (TTL) y devuelve el mensaje a la inbox. |
  | `<servicio>.inbox.dlq` | Guarda los mensajes que agotaron los reintentos. Llegan por `festa.dlx`. |

### Publicar (productor)
- Todo mensaje va en el **sobre** (`envelope.schema.json`): `eventId`, `eventType`, `version`, `occurredAt`, `producer`, `correlationId`, `causationId` y `data`.
- **Transactional outbox:** el cambio de estado y el mensaje se guardan en la **misma transacción** (tabla `outbox`). Un worker publica los pendientes y los marca como enviados. Así nunca hay un cambio guardado sin su evento, ni un evento de algo que se revirtió.
- **Publisher confirms** activados. Si no hay confirmación, el mensaje sigue en la outbox y se reintenta.
- Propiedades AMQP:
  - `persistent: true`
  - `content_type: application/json`
  - `message_id: eventId`
  - `type: eventType`
  - header `x-correlation-id`
- Validar `data` contra el esquema antes de publicar, al menos en los tests.

### Consumir
- **Idempotencia:** guardar el `eventId` procesado (tabla/colección `processed_events`) en la misma transacción que el efecto. Los duplicados se confirman con ack y se ignoran.
- **Validar** `data` contra el esquema. Si no cumple, es un error permanente: va directo a la DLQ, sin reintentos.
- **Errores transitorios** (BD caída, timeout):
  1. Se republica en `<servicio>.inbox.retry` con el header `x-retry-count` incrementado, y se hace ack del original.
  2. Desde el 4.º intento (`x-retry-count >= 3`) se hace `nack(requeue=false)` y el mensaje va a la DLQ.
- **Orden:** los mensajes pueden llegar desordenados. Los snapshots de evento llevan `version`; un consumidor ignora `version <= la guardada`.
- `prefetch` de 10. Los mensajes de la DLQ se revisan y reinyectan a mano desde la UI de RabbitMQ (suficiente para el piloto).

### Evolución
- Agregar campos **opcionales** no rompe nada: los consumidores ignoran lo que no conocen. Por eso validan con `additionalProperties` relajado; el esquema estricto es para el productor.
- Quitar/renombrar campos o volver obligatorio uno nuevo exige un nuevo `x-version` y publicar ambas versiones mientras los consumidores migran.

## Catálogo (38 eventos)

### `festa.auth` — publica auth-service

| Routing key | Qué significa | Consumidores (para qué) |
|---|---|---|
| `account.registered` | Se creó una cuenta (email o Google). | **user**: crea el perfil vacío<br>**notification**: registra el rol (para saber a quién avisar como admin)<br>**analytics**: cuenta registros |
| `account.role_changed` | Cambió el rol de una cuenta (p. ej. un admin promueve a otro admin). Aplica en el siguiente refresh del token. | **notification**: actualiza la lista de admins a notificar |
| `account.deleted` | El usuario borró su cuenta (Ley 1581, derecho de supresión). Cada servicio borra o anonimiza sus datos personales. | **user**: borra perfil, intereses y reportes hechos<br>**event**: cancela sus eventos futuros y anonimiza el organizador<br>**booking**: anonimiza asistencias y revoca pases futuros<br>**payment**: anonimiza al comprador (las órdenes se conservan por contabilidad)<br>**ai**: borra historial de chat y preferencias<br>**notification**: borra tokens FCM y ubicación<br>**analytics**: elimina el userId de sus agregados |

### `festa.user` — publica user-service

| Routing key | Qué significa | Consumidores (para qué) |
|---|---|---|
| `profile.updated` | Cambiaron nombre, intereses o zona preferida del usuario. | **ai**: contexto para recomendaciones<br>**notification**: segmentar push por intereses |
| `location_consent.granted` | RNF5: el usuario aceptó explícitamente el uso de su ubicación. | **notification**: habilita push por cercanía<br>**ai**: puede usar la ubicación enviada en el chat |
| `location_consent.revoked` | RNF5: el usuario retiró el consentimiento. Hay que borrar la ubicación guardada. | **notification**: borra la última ubicación y deja de enviar push por cercanía<br>**ai**: deja de usar ubicación |
| `merchant.submitted` | Un comercio envió (o reenvió) su perfil para verificación manual. | **notification**: avisa a los admins<br>**analytics**: cuenta solicitudes pendientes |
| `merchant.verified` | Un admin verificó el comercio. Desde ahora puede publicar eventos con boletería. | **event**: habilita boletería para sus eventos (proyección de comercios verificados)<br>**payment**: registra al comercio para liquidaciones<br>**notification**: avisa al comercio<br>**analytics**: crea el panel del comercio |
| `merchant.rejected` | Un admin rechazó la verificación. El comercio puede corregir y reenviar. | **notification**: avisa al comercio con el motivo |
| `merchant.updated` | Un comercio verificado cambió nombre, categoría o ubicación. | **event**: actualiza organizerName en sus eventos<br>**payment**: actualiza datos de liquidación<br>**ai**: contexto para descripciones y recomendaciones |
| `report.created` | RF14: alguien reportó un evento o un usuario. | **notification**: avisa a los admins<br>**analytics**: cuenta reportes |
| `report.resolved` | RF14: un admin cerró un reporte. Si hubo acción, además sale un moderation.*. | **notification**: avisa a quien reportó<br>**analytics**: tiempo de resolución |
| `moderation.user_suspended` | Un admin suspendió una cuenta. | **auth**: bloquea login y revoca refresh tokens<br>**event**: oculta sus eventos (status hidden)<br>**notification**: deja de enviarle push |
| `moderation.user_reinstated` | Un admin levantó la suspensión. | **auth**: habilita login<br>**event**: vuelve a mostrar sus eventos vigentes<br>**notification**: reanuda push |
| `moderation.event_hidden` | Un admin ocultó un evento. event-service lo pasa a hidden y publica event.updated. | **event**: status = hidden |
| `moderation.event_restored` | Un admin volvió a mostrar un evento oculto. | **event**: status = published (si no ha expirado) |

### `festa.event` — publica event-service

| Routing key | Qué significa | Consumidores (para qué) |
|---|---|---|
| `event.published` | Evento nuevo visible en el mapa. Snapshot completo. | **booking**: proyección de cupo para RSVP y check-in<br>**payment**: proyección de precio y cupo para vender<br>**ai**: catálogo para recomendar<br>**notification**: push a usuarios cercanos con consentimiento e intereses afines (RF12)<br>**analytics**: crea contadores del evento |
| `event.updated` | Cambió un evento (incluye ocultar/mostrar por moderación). Snapshot completo, no diff. | **booking**: actualiza proyección<br>**payment**: actualiza proyección (hidden = no vender)<br>**ai**: actualiza catálogo<br>**analytics**: actualiza metadatos |
| `event.rescheduled` | Cambio crítico de fecha/hora o lugar. Además del event.updated, para avisar a los asistentes. | **notification**: avisa a los asistentes confirmados y reprograma recordatorios<br>**analytics**: cuenta reprogramaciones |
| `event.cancelled` | El organizador canceló el evento. | **booking**: revoca pases y cancela asistencias<br>**payment**: deja de vender y pide reembolso de órdenes aprobadas<br>**ai**: lo quita del catálogo<br>**notification**: avisa a los asistentes<br>**analytics**: marca el evento |
| `event.sold_out` | attendeeCount alcanzó el cupo. | **ai**: no lo recomienda<br>**analytics**: registra cuándo se agotó |
| `event.expired` | El evento terminó (endsAt pasó) o un Parche en Vivo expiró. Sale del mapa. | **booking**: cierra el check-in<br>**payment**: cierra la venta y expira órdenes pendientes<br>**ai**: lo quita del catálogo<br>**analytics**: congela los contadores |
| `engagement.viewed` | Alguien abrió el detalle de un evento (visibilidad para el comercio). | **analytics**: cuenta vistas por evento y por origen |
| `engagement.shared` | RF13: alguien compartió el evento con el share nativo. | **analytics**: cuenta compartidos |

### `festa.booking` — publica booking-service

| Routing key | Qué significa | Consumidores (para qué) |
|---|---|---|
| `attendance.confirmed` | Asistencia confirmada: RSVP gratis (RF7) o boletas emitidas tras un pago aprobado. Trae el conteo total. | **event**: actualiza attendeeCount (y detecta sold out)<br>**notification**: confirma al usuario y programa recordatorios<br>**analytics**: cuenta asistentes |
| `attendance.cancelled` | Se canceló una asistencia (el usuario, el evento se canceló, o reembolso). Sus pases quedan revocados. | **event**: actualiza attendeeCount<br>**notification**: cancela recordatorios<br>**analytics**: descuenta asistentes |
| `pass.checked_in` | RF10: un QR válido se escaneó en la entrada. Se publica una sola vez por pase (un solo uso). | **notification**: mensaje de bienvenida al asistente<br>**analytics**: cuenta ingresos reales |
| `pass.check_in_rejected` | Se escaneó un QR que no se aceptó. Sirve para detectar fraude (QR reusado o falso). | **analytics**: cuenta intentos rechazados por motivo |

### `festa.payment` — publica payment-service

| Routing key | Qué significa | Consumidores (para qué) |
|---|---|---|
| `order.created` | Se creó una orden y se retuvieron los cupos mientras el usuario paga en Wompi. | **analytics**: embudo: intentos de compra |
| `order.approved` | Wompi aprobó el pago (webhook con firma verificada). | **booking**: crea la asistencia y un pase QR por boleta<br>**notification**: envía el recibo<br>**analytics**: boletos vendidos e ingresos |
| `order.failed` | Wompi rechazó, anuló o falló el pago. Los cupos retenidos se liberan. | **notification**: avisa al comprador<br>**analytics**: embudo: pagos fallidos |
| `order.expired` | La orden venció sin pago confirmado. Los cupos retenidos se liberan. | **notification**: avisa que la reserva venció<br>**analytics**: embudo: abandono |
| `order.refund_requested` | La orden aprobada debe reembolsarse (p. ej. el evento se canceló). Queda pendiente de que un admin la cierre. | **notification**: avisa al comprador que su reembolso está en trámite<br>**analytics**: reembolsos pendientes |
| `order.refunded` | Un admin registró que el reembolso se hizo. | **booking**: revoca los pases de la orden<br>**notification**: confirma al comprador<br>**analytics**: descuenta ingresos |
| `payout.recorded` | Un admin registró una liquidación (transferencia manual) a un comercio. | **notification**: avisa al comercio<br>**analytics**: dinero liquidado vs pendiente |

### `festa.ai` — publica ai-service

| Routing key | Qué significa | Consumidores (para qué) |
|---|---|---|
| `description.generated` | RF9: la IA redactó una descripción (una sola vez por borrador, RNF8). | **analytics**: costo de IA (tokens) por comercio |
| `recommendation.served` | RF8: el chat recomendó eventos concretos en una respuesta. | **analytics**: "veces recomendado" por evento (visibilidad para el comercio) y costo de IA |

### `festa.notification` — publica notification-service

| Routing key | Qué significa | Consumidores (para qué) |
|---|---|---|
| `push.sent` | Se envió un lote de push (alcance para el comercio y control de spam). | **analytics**: personas alcanzadas por evento |

## Qué consume cada servicio

| Servicio | Eventos |
|---|---|
| ai | `account.deleted`, `profile.updated`, `location_consent.granted`, `location_consent.revoked`, `merchant.updated`, `event.published`, `event.updated`, `event.cancelled`, `event.sold_out`, `event.expired` |
| analytics | `account.registered`, `account.deleted`, `merchant.submitted`, `merchant.verified`, `report.created`, `report.resolved`, `event.published`, `event.updated`, `event.rescheduled`, `event.cancelled`, `event.sold_out`, `event.expired`, `engagement.viewed`, `engagement.shared`, `attendance.confirmed`, `attendance.cancelled`, `pass.checked_in`, `pass.check_in_rejected`, `order.created`, `order.approved`, `order.failed`, `order.expired`, `order.refund_requested`, `order.refunded`, `payout.recorded`, `description.generated`, `recommendation.served`, `push.sent` |
| auth | `moderation.user_suspended`, `moderation.user_reinstated` |
| booking | `account.deleted`, `event.published`, `event.updated`, `event.cancelled`, `event.expired`, `order.approved`, `order.refunded` |
| event | `account.deleted`, `merchant.verified`, `merchant.updated`, `moderation.user_suspended`, `moderation.user_reinstated`, `moderation.event_hidden`, `moderation.event_restored`, `attendance.confirmed`, `attendance.cancelled` |
| notification | `account.registered`, `account.role_changed`, `account.deleted`, `profile.updated`, `location_consent.granted`, `location_consent.revoked`, `merchant.submitted`, `merchant.verified`, `merchant.rejected`, `report.created`, `report.resolved`, `moderation.user_suspended`, `moderation.user_reinstated`, `event.published`, `event.rescheduled`, `event.cancelled`, `attendance.confirmed`, `attendance.cancelled`, `pass.checked_in`, `order.approved`, `order.failed`, `order.expired`, `order.refund_requested`, `order.refunded`, `payout.recorded` |
| payment | `account.deleted`, `merchant.verified`, `merchant.updated`, `event.published`, `event.updated`, `event.cancelled`, `event.expired` |
| user | `account.registered`, `account.deleted` |

## Flujos principales

### Compra de boletas (RF11 → RF10)

No hay llamadas síncronas entre servicios.

1. **Precio y cupo:** payment-service conoce el precio y el cupo de cada evento con boletería por su proyección de `event.published` / `event.updated`.
2. **Crear la orden:** la app llama `POST /api/payments/orders {eventId, quantity}`. payment:
   - retiene los cupos con una orden `PENDING`, que vence a los 15 min;
   - publica `order.created`;
   - devuelve a la app los datos para el Widget de Wompi (referencia y firma de integridad).

   La app nunca envía datos de tarjeta a Festa.
3. **Respuesta de Wompi:** Wompi llama `POST /webhooks/wompi` y payment verifica la firma. Según el resultado publica `order.approved` u `order.failed`. Además, un job publica `order.expired` para las órdenes que vencen sin pago.
4. **Emitir las boletas:** booking consume `order.approved`, crea la asistencia con **un pase QR por boleta** y publica `attendance.confirmed{source:ticket}`.
5. **Actualizar el mapa:** event-service consume `attendance.confirmed`, actualiza `attendeeCount` y, si se llenó el cupo, publica `event.sold_out`.

### Asistencia gratis (RF7)

La app llama `POST /api/bookings/events/{id}/attendance`. booking valida el cupo con su proyección y publica `attendance.confirmed{source:rsvp}`, con un pase QR.

### Ingreso (RF10)

El organizador escanea el QR y la app llama `POST /api/bookings/passes/check-in {qr}`. booking:
1. verifica la firma HMAC del QR;
2. comprueba que el evento coincide y que está en la ventana de ingreso;
3. marca el pase de forma atómica, para que sirva una sola vez: `UPDATE pass SET used_at=now() WHERE id=? AND used_at IS NULL AND revoked_at IS NULL`;
4. publica `pass.checked_in`, o `pass.check_in_rejected` con el motivo.

### Evento cancelado

1. event-service publica `event.cancelled`.
2. booking revoca los pases y publica `attendance.cancelled{reason:event_cancelled}`.
3. payment publica `order.refund_requested` por cada orden aprobada.
4. Un admin hace el reembolso y lo registra; payment publica `order.refunded`.

### Verificación de comercio (RF3)

1. El comercio se registra con `role=merchant`.
2. user-service publica `merchant.submitted` y los admins reciben aviso.
3. El admin aprueba y user-service publica `merchant.verified`:
   - event-service habilita la boletería;
   - payment registra al comercio para liquidaciones.
4. Si el admin lo rechaza, user-service publica `merchant.rejected` y el comercio puede corregir y reenviar.

### Moderación (RF14)

1. Alguien reporta y user-service publica `report.created`.
2. Un admin decide y user-service publica `report.resolved`. Si hubo acción, publica además uno de estos:
   - `moderation.user_suspended`: auth bloquea el login y revoca los refresh tokens; event oculta los eventos de la cuenta.
   - `moderation.event_hidden`: event-service pasa el evento a `status=hidden` y publica `event.updated`.

### Borrado de cuenta (Ley 1581)

auth-service publica `account.deleted`. Cada servicio borra o anonimiza sus datos personales: las órdenes se conservan anonimizadas por contabilidad.

## Validar

```bash
cd contracts && npm install && npm run validate
```
