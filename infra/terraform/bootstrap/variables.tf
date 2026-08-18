variable "project_id" {
  description = "ID do único projeto GCP, usado tanto por dev quanto por prod."
  type        = string
  default     = "observability-hub"
}

variable "region" {
  description = "Região padrão dos recursos."
  type        = string
  default     = "us-central1"
}

variable "github_repository" {
  description = "Repositório GitHub autorizado a assumir as identidades (org/repo)."
  type        = string
  default     = "Matheus-Fuzati-de-Carvalho/gcp-hub"
}
