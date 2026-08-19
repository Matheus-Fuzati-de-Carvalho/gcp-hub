output "state_bucket_name" {
  value = module.bootstrap.state_bucket_name
}

output "workload_identity_providers" {
  description = "Mapa ambiente -> provider (\"dev\" e \"prod\") — valores diferentes, um provider por ambiente."
  value       = module.bootstrap.workload_identity_providers
}

output "service_account_emails" {
  description = "Mapa ambiente -> e-mail (\"dev\" e \"prod\")."
  value       = module.bootstrap.service_account_emails
}
