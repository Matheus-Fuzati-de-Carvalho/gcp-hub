module "backend_cloud_run" {
  source = "../../modules/cloud-run"

  project_id = var.project_id
  region     = var.region
  # Sufixado por ambiente: dev e prod rodam no mesmo projeto GCP (topologia
  # single-project deste repositório), então "backend" sozinho colidiria
  # com o serviço Cloud Run de dev (e com a SA de runtime, derivada do
  # mesmo nome — ver modules/cloud-run/main.tf).
  service_name = "backend-prod"
  image        = var.backend_image

  # O repositório Artifact Registry "apps" já é gerenciado pelo
  # backend_cloud_run de dev, neste mesmo projeto — só uma instância do
  # módulo pode ser dona, as outras três (frontend-dev, backend-prod,
  # frontend-prod) reaproveitam via manage_artifact_registry = false.
  manage_artifact_registry = false

  # Ambiente de prod: protege o serviço contra destroy acidental.
  deletion_protection   = true
  allow_unauthenticated = true

  # Libera CORS pras duas URLs válidas do frontend em prod — todo Cloud Run
  # responde tanto na URL canônica (com hash) quanto na URL legada baseada
  # no número do projeto, e o browser pode acessar por qualquer uma das duas.
  env = {
    OBSERVABILITY_HUB_CORS_ORIGINS = "${module.frontend_cloud_run.service_url},${module.frontend_cloud_run.service_url_alt}"
    # Único sinal de ambiente do backend (core/config.py::settings.environment)
    # — nunca mais inferido do project_id, que é o mesmo pros dois ambientes
    # nesta topologia.
    OBSERVABILITY_HUB_ENVIRONMENT = "prod"
  }
}

module "frontend_cloud_run" {
  source = "../../modules/cloud-run"

  project_id   = var.project_id
  region       = var.region
  service_name = "frontend-prod"
  image        = var.frontend_image

  # Frontend estático (serve -s dist) não tem endpoint /health — a raiz
  # responde 200 e serve pros probes de startup/liveness.
  health_check_path = "/"

  # Reaproveita o repositório Artifact Registry criado pelo backend_cloud_run
  # de dev, neste mesmo projeto (ver comentário acima).
  manage_artifact_registry = false

  # Ambiente de prod: protege o serviço contra destroy acidental.
  deletion_protection   = true
  allow_unauthenticated = true
}

# Firestore named database do ambiente prod — dev e prod estão no mesmo
# projeto GCP, então não dá pra usar o banco "(default)" implícito pros
# dois (misturaria dados). Precisa existir antes do primeiro deploy do
# backend (core/firestore.py::get_firestore_client usa database="prod").
resource "google_firestore_database" "hub" {
  project     = var.project_id
  name        = "prod"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  # Ambiente de prod: protege contra destroy acidental do banco inteiro.
  delete_protection_state = "DELETE_PROTECTION_ENABLED"
  deletion_policy         = "ABANDON"
}
