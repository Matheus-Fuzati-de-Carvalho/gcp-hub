output "state_bucket_name" {
  description = "Nome do bucket GCS de remote state, compartilhado por dev e prod."
  value       = google_storage_bucket.tfstate.name
}

output "workload_identity_provider" {
  description = "Nome completo do provider, usado em google-github-actions/auth (input workload_identity_provider) — o mesmo valor pros workflows de dev e de prod."
  value       = google_iam_workload_identity_pool_provider.github_provider.name
}

output "service_account_emails" {
  description = "Mapa ambiente -> e-mail da service account de deploy que o GitHub Actions impersona (input service_account de google-github-actions/auth)."
  value       = { for env, sa in google_service_account.deployer : env => sa.email }
}
