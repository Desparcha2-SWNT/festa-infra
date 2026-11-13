#!/usr/bin/env node
// Prueba de humo de punta a punta: recorre el MVP completo a través del gateway (Kong), como lo haría
// la app. Requiere el stack arriba con PAYMENTS_ALLOW_SIMULATION=true:
//
//   docker compose --profile all up -d --build
//   node scripts/e2e/smoke.mjs                 # GATEWAY_URL=http://localhost:8000 por defecto
//
// Lee ADMIN_EMAIL / ADMIN_PASSWORD (y ALLOWED_EMAIL_DOMAIN) de las variables de entorno o, si no están, de
// .env. Contra AWS: GATEWAY_URL=<api_base_url> ADMIN_PASSWORD=<de Secrets Manager> node scripts/e2e/smoke.mjs
// (con payments_allow_simulation=true en Terraform). Sale con código 1 si algún paso falla.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const fileEnv = Object.fromEntries(
  fs.existsSync(path.join(root, '.env'))
    ? fs.readFileSync(path.join(root, '.env'), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)])
    : [],
);
const pick = (name) => process.env[name] || fileEnv[name];
const env = {
  ADMIN_EMAIL: pick('ADMIN_EMAIL') || 'admin@escuelaing.edu.co',
  ADMIN_PASSWORD: pick('ADMIN_PASSWORD'),
  ALLOWED_EMAIL_DOMAIN: pick('ALLOWED_EMAIL_DOMAIN'),
};
const GATEWAY = process.env.GATEWAY_URL ?? 'http://localhost:8000';
const DOMAIN = env.ALLOWED_EMAIL_DOMAIN || 'escuelaing.edu.co';
const run = crypto.randomBytes(3).toString('hex');
// Contraseña de los usuarios de prueba: nueva en cada corrida, con mayúscula, minúscula y número.
const testPassword = `Festa-${crypto.randomBytes(6).toString('hex')}9`;

let step = 0;
const ok = (msg) => console.log(`  ✓ ${msg}`);
const title = (msg) => console.log(`\n${++step}. ${msg}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, url, { token, body, expect = [200, 201, 202, 204], headers = {} } = {}) {
  const res = await fetch(`${GATEWAY}${url}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!expect.includes(res.status)) {
    throw new Error(`${method} ${url} → ${res.status} ${typeof data === 'string' ? data : JSON.stringify(data)}`);
  }
  return { status: res.status, data };
}

/** Repite `fn` hasta que devuelva algo truthy (la mensajería es asíncrona). */
async function eventually(what, fn, { timeoutMs = 30_000 } = {}) {
  const start = Date.now();
  let lastErr;
  while (Date.now() - start < timeoutMs) {
    try {
      const value = await fn();
      if (value) return value;
    } catch (err) {
      lastErr = err;
    }
    await sleep(1000);
  }
  throw new Error(`no se cumplió a tiempo: ${what}${lastErr ? ` (${lastErr.message})` : ''}`);
}

const register = async (name, accountType) => {
  const email = `${name}.${run}@${DOMAIN}`;
  const { data } = await api('POST', '/api/auth/register', {
    body: { email, password: testPassword, displayName: `${name} ${run}`, accountType, acceptedPrivacyPolicy: true },
  });
  return { token: data.accessToken, id: data.account.id, email };
};

async function main() {
  console.log(`Festa · prueba de punta a punta contra ${GATEWAY} (corrida ${run})`);

  title('RF1: registro e inicio de sesión');
  const admin = (await api('POST', '/api/auth/login', { body: { email: env.ADMIN_EMAIL, password: env.ADMIN_PASSWORD } })).data;
  ok(`admin ${admin.account.id}`);
  const merchant = await register('comercio', 'merchant');
  const user = await register('estudiante', 'user');
  ok(`comercio ${merchant.id} y estudiante ${user.id}`);

  title('RF2: perfil creado por account.registered y consentimiento de ubicación (RNF5)');
  await eventually('perfil del estudiante', async () => (await api('GET', '/api/users/me', { token: user.token })).data);
  await api('PUT', '/api/users/me/interests', { token: user.token, body: { interests: ['MUSICAL', 'GASTRONOMICO'] }, expect: [200, 204] });
  await api('POST', '/api/users/me/consents', { token: user.token, body: { type: 'LOCATION', granted: true, version: '2026-10' } });
  await eventually('notification registra el consentimiento', async () =>
    (await api('PUT', '/api/notifications/location', { token: user.token, body: { lat: 4.7826, lng: -74.0426 }, expect: [204, 403] })).status === 204,
  );
  ok('perfil, intereses, consentimiento y ubicación');

  title('RF3: el comercio solicita verificación y un admin la aprueba');
  await eventually('perfil del comercio', async () => (await api('GET', '/api/users/me', { token: merchant.token })).data);
  await api('POST', '/api/users/me/merchant', {
    token: merchant.token,
    body: { businessName: `Café Bohemio ${run}`, category: 'GASTRONOMICO', address: 'Autopista Norte km 13', latitude: 4.7826, longitude: -74.0426 },
  });
  await api('POST', `/api/users/admin/merchants/${merchant.id}/approve`, { token: admin.accessToken });
  ok('comercio verificado');

  title('RF9: descripción del evento con IA (una sola vez por borrador)');
  const draftId = crypto.randomUUID();
  const desc = (await api('POST', '/api/ai/descriptions', {
    token: merchant.token,
    body: { draftId, name: 'Noche de jazz', location: 'Café Bohemio', activityType: 'concierto de jazz en vivo', category: 'musical' },
  })).data;
  const again = (await api('POST', '/api/ai/descriptions', {
    token: merchant.token,
    body: { draftId, name: 'Noche de jazz', location: 'Café Bohemio', activityType: 'concierto de jazz en vivo', category: 'musical' },
  })).data;
  if (!again.cached) throw new Error('la segunda descripción debía venir guardada (RNF8)');
  ok(`"${desc.description.slice(0, 70)}…" (${desc.provider})`);

  title('RF4: el comercio crea un evento con boletería y un Parche en Vivo gratis (RF19)');
  const startsAt = new Date(Date.now() + 30 * 60_000).toISOString();
  const endsAt = new Date(Date.now() + 4 * 3600_000).toISOString();
  const venue = { name: 'Café Bohemio', address: 'Autopista Norte km 13', location: { lat: 4.7830, lng: -74.0420 } };
  const ticketed = (await eventually('event-service conoce el comercio verificado', async () =>
    (await api('POST', '/api/events', {
      token: merchant.token,
      expect: [201, 403],
      body: {
        organizerType: 'merchant', merchantId: merchant.id, organizerName: `Café Bohemio ${run}`, title: `Noche de jazz ${run}`,
        description: desc.description, descriptionAiGenerated: true, category: 'musical', startsAt, endsAt, venue,
        capacity: 5, ticketed: true, priceCents: 2_000_000, maxTicketsPerOrder: 4,
      },
    })).status === 201 && (await api('GET', '/api/events/mine', { token: merchant.token })).data.items.find((e) => e.ticketed && e.title.endsWith(run)),
  ));
  const live = (await api('POST', '/api/events', {
    token: merchant.token,
    body: {
      organizerType: 'user', organizerName: 'Comercio', title: `Parche de café ${run}`, description: 'Café gratis para los primeros',
      category: 'gastronomico', isLive: true, startsAt: new Date().toISOString(), endsAt: new Date(Date.now() + 2 * 3600_000).toISOString(),
      venue, capacity: 10,
    },
  })).data;
  ok(`evento ${ticketed.eventId} y parche ${live.eventId}`);

  title('RF5/RF6: el mapa y la búsqueda los muestran');
  const found = (await api('GET', `/api/events?bbox=-74.06,4.77,-74.03,4.80&q=${run}`, { token: user.token })).data.items;
  if (found.length < 2) throw new Error(`la búsqueda devolvió ${found.length} eventos`);
  const onlyLive = (await api('GET', `/api/events?live=true&q=${run}`, { token: user.token })).data.items;
  if (onlyLive.length !== 1) throw new Error('el filtro de Parches en Vivo no funcionó');
  ok(`${found.length} eventos en el recuadro, 1 en vivo`);

  title('RF8: el chat de IA recomienda eventos reales');
  const chat = (await eventually('ai-service tiene el catálogo', async () => {
    const r = (await api('POST', '/api/ai/chat', { token: user.token, body: { message: 'quiero escuchar jazz o música en vivo hoy' } })).data;
    return r.events.length > 0 && r;
  }));
  ok(`"${chat.reply.slice(0, 60)}…" → ${chat.events.map((e) => e.title).join(', ')}`);

  title('RF7: confirmación de asistencia gratis y conteo');
  await eventually('booking conoce el parche', async () => (await api('POST', `/api/bookings/events/${live.eventId}/attendance`, { token: user.token, expect: [201, 404] })).status === 201);
  const count = await eventually('event-service actualiza el conteo', async () => {
    const e = (await api('GET', `/api/events/${live.eventId}`, { token: user.token })).data;
    return e.attendeeCount === 1 && e;
  });
  ok(`asistentes: ${count.attendeeCount}`);

  title('RF11: compra de 2 boletas con comisión (pago simulado de Wompi)');
  const quote = (await eventually('payment conoce el evento', async () =>
    (await api('GET', `/api/payments/events/${ticketed.eventId}/quote?quantity=2`, { token: user.token })).data,
  ));
  const order = (await api('POST', '/api/payments/orders', { token: user.token, body: { eventId: ticketed.eventId, quantity: 2 }, headers: { 'idempotency-key': `smoke-${run}` } })).data;
  if (!order.checkout?.checkoutUrl) throw new Error('la orden no trae el checkout de Wompi');
  await api('POST', `/api/payments/orders/${order.orderId}/simulate`, { token: user.token, body: { status: 'APPROVED' } });
  ok(`total ${quote.totalCents / 100} COP (comisión ${quote.commissionCents / 100}); orden aprobada`);

  title('RF10: booking emite un QR por boleta; el ingreso sirve una sola vez');
  const passes = await eventually('booking emite las boletas', async () => {
    const items = (await api('GET', '/api/bookings/passes/mine', { token: user.token })).data.items.filter((p) => p.eventId === ticketed.eventId);
    return items.length === 2 && items;
  });
  const scan = (qr) => api('POST', '/api/bookings/passes/check-in', { token: merchant.token, body: { qr, eventId: ticketed.eventId }, expect: [200, 403, 409] });
  const first = await scan(passes[0].qr);
  const second = await scan(passes[0].qr);
  const stranger = await api('POST', '/api/bookings/passes/check-in', { token: user.token, body: { qr: passes[1].qr, eventId: ticketed.eventId }, expect: [403] });
  if (first.status !== 200 || second.data.code !== 'already_used' || stranger.data.code !== 'not_organizer') {
    throw new Error(`check-in inesperado: ${JSON.stringify([first.data, second.data, stranger.data])}`);
  }
  ok('primer ingreso válido, reuso rechazado (already_used), un no organizador rechazado');

  title('RF12: notificaciones en la bandeja');
  const inbox = await eventually('notification registra los avisos', async () => {
    const items = (await api('GET', '/api/notifications', { token: user.token })).data.items;
    return items.some((n) => n.kind === 'ticket') && items;
  });
  ok(inbox.slice(0, 4).map((n) => n.title).join(' · '));

  title('RF15: panel del comercio');
  const panel = await eventually('analytics cuenta la venta', async () => {
    const p = (await api('GET', '/api/analytics/merchants/me', { token: merchant.token })).data;
    return p.totals.ticketsSold === 2 && p.totals.checkIns >= 1 && p;
  });
  ok(`boletas ${panel.totals.ticketsSold}, ingresos ${panel.totals.checkIns}, asistentes ${panel.totals.attendees}`);

  title('RF14: reporte y moderación');
  const report = (await api('POST', '/api/reports', { token: user.token, body: { targetType: 'event', targetId: live.eventId, reason: 'spam' } })).data;
  await api('POST', `/api/users/admin/reports/${report.reportId}/resolve`, { token: admin.accessToken, body: { outcome: 'action_taken', action: 'hide_event' } });
  await eventually('event-service oculta el parche', async () =>
    !(await api('GET', `/api/events?q=${run}`, { token: user.token })).data.items.some((e) => e.eventId === live.eventId),
  );
  ok('evento reportado y oculto del mapa');

  title('Evento cancelado: reembolso pedido, admin reembolsa y los pases se revocan');
  const cancelOrder = (await api('POST', '/api/payments/orders', { token: user.token, body: { eventId: ticketed.eventId, quantity: 1 } })).data;
  await api('POST', `/api/payments/orders/${cancelOrder.orderId}/simulate`, { token: user.token, body: { status: 'APPROVED' } });
  await eventually('booking emite la tercera boleta', async () =>
    (await api('GET', '/api/bookings/passes/mine', { token: user.token })).data.items.filter((p) => p.eventId === ticketed.eventId).length === 3,
  );
  await api('POST', `/api/events/${ticketed.eventId}/cancel`, { token: merchant.token, body: { reason: 'Lluvia fuerte' } });
  const refunds = await eventually('payment pide los reembolsos', async () => {
    const items = (await api('GET', '/api/payments/admin/refunds', { token: admin.accessToken })).data.items.filter((o) => [order.orderId, cancelOrder.orderId].includes(o.orderId));
    return items.length === 2 && items;
  });
  for (const r of refunds) await api('POST', `/api/payments/admin/orders/${r.orderId}/refund`, { token: admin.accessToken, body: { reference: `Reverso ${run}` } });
  await eventually('booking revoca todos los pases', async () =>
    (await api('GET', '/api/bookings/passes/mine', { token: user.token })).data.items.filter((p) => p.eventId === ticketed.eventId).every((p) => p.status !== 'valid'),
  );
  await eventually('el comprador recibe el aviso de reembolso', async () =>
    (await api('GET', '/api/notifications', { token: user.token })).data.items.some((n) => n.title === 'Reembolso realizado'),
  );
  ok(`${refunds.length} órdenes reembolsadas, pases revocados y comprador notificado`);

  const kpis = (await api('GET', '/api/analytics/admin/overview?days=1', { token: admin.accessToken })).data;
  console.log(`\n✅ Todo el flujo funcionó. KPIs de hoy: ${kpis.users.registrations} registros, ${kpis.sales.ticketsSold} boletas, comisión ${kpis.sales.commissionCents / 100} COP.`);
}

main().catch((err) => {
  console.error(`\n❌ Falló el paso ${step}: ${err.message}`);
  process.exit(1);
});
