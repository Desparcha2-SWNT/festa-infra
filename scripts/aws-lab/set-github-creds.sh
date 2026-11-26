#!/usr/bin/env bash
# Copia las credenciales de la sesión actual del Learner Lab a los secrets del environment `aws-lab` de
# festa-infra, para que el workflow "Deploy AWS lab" pueda desplegar. Hay que correrlo cada vez que se
# enciende el lab (las credenciales vencen con la sesión, unas 4 horas).
#
# Uso: en el lab, "AWS Details" → "AWS CLI" → copiar el bloque [default] y pegarlo en la entrada estándar:
#
#   ./scripts/aws-lab/set-github-creds.sh        # pega el bloque y termina con Ctrl+D
#
# Necesita `gh` autenticado con permiso de administrar secrets en el repo. Las credenciales no se guardan en
# disco ni se imprimen.
set -euo pipefail

REPO="${REPO:-Desparcha2-SWNT/festa-infra}"
ENVIRONMENT="${ENVIRONMENT:-aws-lab}"

echo "Pega el bloque [default] de AWS Details y termina con Ctrl+D:" >&2
block=$(cat)

value() { printf '%s\n' "$block" | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | tr -d '\r' | head -1; }
key_id=$(value aws_access_key_id)
secret=$(value aws_secret_access_key)
token=$(value aws_session_token)

if [ -z "$key_id" ] || [ -z "$secret" ] || [ -z "$token" ]; then
  echo "No encontré aws_access_key_id, aws_secret_access_key y aws_session_token en lo pegado." >&2
  exit 1
fi

# Comprueba que sirven antes de guardarlas.
account=$(AWS_ACCESS_KEY_ID="$key_id" AWS_SECRET_ACCESS_KEY="$secret" AWS_SESSION_TOKEN="$token" \
  aws sts get-caller-identity --query Account --output text)

printf '%s' "$key_id" | gh secret set AWS_ACCESS_KEY_ID --repo "$REPO" --env "$ENVIRONMENT"
printf '%s' "$secret" | gh secret set AWS_SECRET_ACCESS_KEY --repo "$REPO" --env "$ENVIRONMENT"
printf '%s' "$token" | gh secret set AWS_SESSION_TOKEN --repo "$REPO" --env "$ENVIRONMENT"
echo "Listo: credenciales de la cuenta $account guardadas en $REPO (environment $ENVIRONMENT)." >&2
