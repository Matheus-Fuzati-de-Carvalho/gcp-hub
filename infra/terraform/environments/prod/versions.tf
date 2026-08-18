terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Nome do bucket vem do output `state_bucket_name` do bootstrap (único,
  # compartilhado com dev — topologia single-project). Ver
  # infra/terraform/bootstrap/README.md. O `prefix` é quem isola o state
  # de prod do de dev dentro do mesmo bucket.
  backend "gcs" {
    bucket = "observability-hub-tfstate"
    prefix = "environments/prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
