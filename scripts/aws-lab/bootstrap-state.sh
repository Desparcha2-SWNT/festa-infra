#!/usr/bin/env bash
# Crea (una sola vez por cuenta del Learner Lab) el bucket S3 donde Terraform guarda el estado de
# terraform/aws-lab. Es idempotente: si el bucket ya existe, no hace nada. Imprime el nombre del bucket.
#
#   ./scripts/aws-lab/bootstrap-state.sh            # usa las credenciales del lab ya configuradas
#
# El bucket queda privado, cifrado y con versionado (para recuperar un estado si un apply lo daña).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="festa-tfstate-${ACCOUNT}"

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "$BUCKET"
  exit 0
fi

if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
fi
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

echo "$BUCKET"
