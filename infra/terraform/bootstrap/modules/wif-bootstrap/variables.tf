variable "project_id" {
  description = "ID do único projeto GCP onde o bootstrap é aplicado (compartilhado por dev e prod)."
  type        = string
}

variable "region" {
  description = "Região padrão usada pelo bucket de state e demais recursos regionais."
  type        = string
  default     = "us-central1"
}

variable "github_repository" {
  description = "Repositório GitHub autorizado a assumir as identidades federadas, no formato \"org/repo\"."
  type        = string
}

variable "deploy_identities" {
  description = "Uma entrada por ambiente de deploy a criar (ex: \"dev\", \"prod\"). `restrict_to_ref`, se definido (ex: \"refs/heads/main\"), restringe qual ref do repositório pode impersonar essa identidade especificamente — usado pra restringir só o ambiente prod à branch main, mesmo compartilhando pool/provider com dev."
  type = map(object({
    restrict_to_ref = optional(string)
  }))

  validation {
    condition     = alltrue([for k in keys(var.deploy_identities) : contains(["dev", "prod"], k)])
    error_message = "As chaves de deploy_identities devem ser \"dev\" e/ou \"prod\"."
  }
}

variable "state_bucket_force_destroy" {
  description = "Permite apagar o bucket de state mesmo com objetos dentro. Deve ficar false em uso normal."
  type        = bool
  default     = false
}
