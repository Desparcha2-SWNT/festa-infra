// Valida que:
//  1. cada esquema compile, tenga ejemplo y su ejemplo lo cumpla (también envuelto en el sobre);
//  2. el productor sea el dueño del exchange y cada `required` exista en `properties`;
//  3. rabbitmq/definitions.json tenga exactamente los exchanges y bindings que declaran los esquemas,
//     y cada inbox tenga su cola .retry y su .dlq.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);

const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const envelopeSchema = readJson(path.join(root, 'envelope.schema.json'));
const envelope = ajv.compile(envelopeSchema);
const knownServices = new Set(envelopeSchema.properties.producer.enum);
const errors = [];
const expectedBindings = new Set();
const expectedExchanges = new Set(['festa.dlx']);
let eventCount = 0;

const eventsDir = path.join(root, 'events');
for (const domain of fs.readdirSync(eventsDir)) {
  for (const file of fs.readdirSync(path.join(eventsDir, domain))) {
    eventCount++;
    const schema = readJson(path.join(eventsDir, domain, file));
    const rk = schema['x-routing-key'];
    const ex = schema['x-exchange'];
    const consumers = schema['x-consumers'] ?? {};
    if (file !== `${rk}.schema.json`) errors.push(`${file}: el nombre no coincide con x-routing-key ${rk}`);
    if (ex !== `festa.${domain}`) errors.push(`${file}: x-exchange ${ex} no coincide con la carpeta ${domain}`);
    if (schema['x-producer'] !== `${domain}-service`) errors.push(`${file}: solo ${domain}-service puede publicar en ${ex}`);
    if (!/^[a-z_]+\.[a-z_]+$/.test(rk)) errors.push(`${file}: routing key ${rk} no cumple <agregado>.<verbo>`);
    if (!Object.keys(consumers).length) errors.push(`${file}: no tiene consumidores`);
    for (const [c, purpose] of Object.entries(consumers)) {
      if (!knownServices.has(c)) errors.push(`${file}: consumidor desconocido ${c}`);
      if (c === schema['x-producer']) errors.push(`${file}: ${c} se consume a sí mismo`);
      if (!purpose) errors.push(`${file}: falta el propósito de ${c}`);
      expectedBindings.add(`${ex}|${rk}|${c}.inbox`);
    }
    for (const r of schema.required ?? []) {
      if (!schema.properties?.[r]) errors.push(`${file}: required "${r}" no está en properties`);
    }
    expectedExchanges.add(ex);

    const validate = ajv.compile(schema);
    if (!schema.examples?.length) errors.push(`${file}: sin ejemplos`);
    for (const example of schema.examples ?? []) {
      if (!validate(example)) errors.push(`${file}: ejemplo inválido ${ajv.errorsText(validate.errors)}`);
      const msg = {
        eventId: '1d2e3f4a-5b6c-4d7e-8f9a-0b1c2d3e4f5a', eventType: rk, version: schema['x-version'],
        occurredAt: '2026-10-24T15:00:00Z', producer: schema['x-producer'], correlationId: null, causationId: null, data: example,
      };
      if (!envelope(msg)) errors.push(`${file}: sobre inválido ${ajv.errorsText(envelope.errors)}`);
    }
  }
}

const defs = readJson(path.join(root, 'rabbitmq', 'definitions.json'));
const actualExchanges = new Set(defs.exchanges.map((e) => e.name));
const actualBindings = new Set(
  defs.bindings.filter((b) => b.source !== 'festa.dlx').map((b) => `${b.source}|${b.routing_key}|${b.destination}`),
);
const queues = new Map(defs.queues.map((q) => [q.name, q]));
const diff = (a, b) => [...a].filter((x) => !b.has(x));

for (const x of diff(expectedExchanges, actualExchanges)) errors.push(`falta exchange ${x} en definitions.json`);
for (const x of diff(actualExchanges, expectedExchanges)) errors.push(`exchange ${x} sin esquemas`);
for (const x of diff(expectedBindings, actualBindings)) errors.push(`falta binding ${x}`);
for (const x of diff(actualBindings, expectedBindings)) errors.push(`binding ${x} no declarado en x-consumers`);
for (const [name, q] of queues) {
  if (!name.endsWith('.inbox')) continue;
  if (q.arguments['x-dead-letter-routing-key'] !== `${name}.dlq`) errors.push(`${name}: dead-letter mal configurado`);
  if (!queues.has(`${name}.dlq`)) errors.push(`${name}: falta ${name}.dlq`);
  const retry = queues.get(`${name}.retry`);
  if (!retry) errors.push(`${name}: falta ${name}.retry`);
  else if (retry.arguments['x-dead-letter-routing-key'] !== name || !retry.arguments['x-message-ttl']) {
    errors.push(`${name}.retry: debe tener TTL y devolver a ${name}`);
  }
}

if (errors.length) {
  console.error(errors.map((e) => `✗ ${e}`).join('\n'));
  process.exit(1);
}
console.log(
  `✓ ${eventCount} eventos, ${expectedBindings.size} bindings, ${actualExchanges.size} exchanges, ${queues.size} colas: contratos consistentes`,
);
