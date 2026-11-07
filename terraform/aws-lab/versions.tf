# Despliegue de Festa en el AWS Academy Learner Lab (SCRUM-134, ADR 0001).
# El estado vive en un bucket S3 de la misma cuenta (ver scripts/aws-lab/bootstrap-state.sh); el bucket y la
# llave se pasan con -backend-config para no fijar el número de cuenta en el código.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    # bucket, key y region llegan por -backend-config. use_lockfile evita aplicar dos veces a la vez sin DynamoDB.
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "festa"
      Env       = var.env
      ManagedBy = "terraform"
      Repo      = "Desparcha2-SWNT/festa-infra"
    }
  }
}
