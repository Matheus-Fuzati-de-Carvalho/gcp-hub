locals {
  required_apis = [
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "secretmanager.googleapis.com",
    "logging.googleapis.com",
    "firestore.googleapis.com",
  ]

  # Papéis do SA de deploy: cobre exatamente os módulos já planejados em
  # infra/terraform/modules (cloud-run, artifact-registry, bigquery,
  # secret-manager, logging-sink) mais o necessário para o Cloud Run
  # deploy funcionar. Revisar/apertar conforme os módulos forem escritos.
  # Mesma lista pras duas identidades (dev e prod) — o isolamento entre
  # elas não vem de papéis diferentes, vem de nomes de recurso sufixados
  # por ambiente em todo o resto do Terraform.
  deployer_roles = [
    "roles/run.admin",
    "roles/artifactregistry.admin",
    "roles/bigquery.admin",
    "roles/secretmanager.admin",
    "roles/logging.configWriter",
    "roles/iam.serviceAccountUser",
    # Necessário para o módulo cloud-run criar a service account de runtime
    # do Cloud Run (ex: backend-dev-run) via `terraform apply`. Faltava e
    # causou falha em produção (Error 403: iam.serviceAccounts.create denied).
    "roles/iam.serviceAccountAdmin",
    # Necessário pro google_firestore_database criado em cada ambiente
    # (environments/{dev,prod}/main.tf).
    "roles/datastore.owner",
  ]

  # Cada par (ambiente, role) vira uma google_project_iam_member — flatten
  # manual porque for_each não aninha diretamente.
  deployer_role_bindings = {
    for pair in setproduct(keys(var.deploy_identities), local.deployer_roles) :
    "${pair[0]}-${pair[1]}" => { environment = pair[0], role = pair[1] }
  }
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Um bucket só, compartilhado por dev e prod — topologia single-project.
# O isolamento de state entre os dois ambientes vem do `prefix` em cada
# environments/{dev,prod}/versions.tf, não de bucket separado.
resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-tfstate"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.state_bucket_force_destroy

  versioning {
    enabled = true
  }

  # Guarda contra "terraform destroy" acidental apagando o histórico de
  # state dos dois ambientes que apontam para este bucket.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# Pool e provider únicos — um só de cada, compartilhado pelas identidades
# de deploy de dev e prod (topologia single-project: não há um projeto por
# ambiente pra justificar um pool por ambiente). A restrição "prod só via
# refs/heads/main" NÃO fica aqui (um provider só não pode ter dois
# attribute_condition diferentes) — fica no IAM binding de cada SA de
# deploy, abaixo.
resource "google_iam_workload_identity_pool" "github_pool" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions"
  description               = "Federação de tokens OIDC do GitHub Actions (dev e prod, mesmo projeto)"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Obrigatório: sem attribute_condition, qualquer repositório do GitHub
  # (de qualquer conta) poderia tentar se passar por este pool. Só filtra
  # pelo repositório — a restrição de ref (dev: qualquer branch; prod: só
  # main) é decidida por SA no binding abaixo, não aqui.
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "deployer" {
  for_each = var.deploy_identities

  project      = var.project_id
  account_id   = "gh-deploy-${each.key}"
  display_name = "GitHub Actions deployer (${each.key})"
  description  = "Identidade impersonada pelo GitHub Actions via Workload Identity Federation para terraform apply e deploy no ambiente ${each.key}"
}

resource "google_service_account_iam_member" "wif_binding" {
  for_each = var.deploy_identities

  service_account_id = google_service_account.deployer[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  # Sem restrict_to_ref (dev, hoje): qualquer branch do repositório pode
  # impersonar — espelha "push em qualquer branch -> deploy em dev"
  # (CLAUDE.md). Com restrict_to_ref (prod): só o subject exato daquele
  # ref pode impersonar — GitHub emite google.subject (= assertion.sub) no
  # formato "repo:{org}/{repo}:ref:{ref}" pra um push, então o principal
  # abaixo restringe a exatamente esse subject.
  member = each.value.restrict_to_ref == null ? (
    "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_repository}"
    ) : (
    "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/subject/repo:${var.github_repository}:ref:${each.value.restrict_to_ref}"
  )
}

resource "google_project_iam_member" "deployer_roles" {
  for_each = local.deployer_role_bindings

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.deployer[each.value.environment].email}"
}

resource "google_storage_bucket_iam_member" "deployer_state_access" {
  for_each = var.deploy_identities

  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.deployer[each.key].email}"
}
