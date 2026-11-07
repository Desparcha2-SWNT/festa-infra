#!/usr/bin/env bash
# Genera los secretos locales en ./secrets (ignorado por git). No sobreescribe lo que ya existe.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p secrets

if [ ! -f secrets/jwt_private.pem ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out secrets/jwt_private.pem 2>/dev/null
  openssl pkey -in secrets/jwt_private.pem -pubout -out secrets/jwt_public.pem
  echo "✓ llaves JWT RS256"
fi

if [ ! -f secrets/qr_signing.key ]; then
  openssl rand -base64 32 | tr -d '\n' > secrets/qr_signing.key
  echo "✓ secreto de firma de QR"
fi

# Placeholder para que el bind mount no cree un directorio. Reemplázalo por el JSON real de Firebase.
if [ ! -f secrets/firebase-service-account.json ]; then
  echo '{}' > secrets/firebase-service-account.json
  echo "• secrets/firebase-service-account.json es un placeholder"
fi

if [ -f .env ] && grep -q '^PII_ENCRYPTION_KEY=$' .env; then
  key=$(openssl rand -base64 32 | tr -d '\n')
  sed -i.bak "s#^PII_ENCRYPTION_KEY=\$#PII_ENCRYPTION_KEY=${key}#" .env && rm -f .env.bak
  echo "✓ PII_ENCRYPTION_KEY escrita en .env"
fi
