variable "project_id" {
  description = "ID do único projeto GCP, compartilhado com o ambiente prod (topologia single-project deste repositório)."
  type        = string
  default     = "observability-hub"
}

variable "region" {
  description = "Região padrão dos recursos."
  type        = string
  default     = "us-central1"
}

variable "backend_image" {
  description = "Imagem do backend. Deixe o default (placeholder) no primeiro apply; os workflows de deploy atualizam a revisão depois via gcloud run deploy."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "frontend_image" {
  description = "Imagem do frontend. Deixe o default (placeholder) no primeiro apply; os workflows de deploy atualizam a revisão depois via gcloud run deploy."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}
