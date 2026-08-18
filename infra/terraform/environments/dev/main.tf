module "backend_cloud_run" {
  source = "../../modules/cloud-run"

  project_id = var.project_id
  region     = var.region
  # Sufixado por ambiente: dev e prod rodam no mesmo projeto GCP (topologia
  # single-project deste repositório), então "backend" sozinho colidiria
  # com o serviço Cloud Run de prod (e com a SA de runtime, derivada do
  # mesmo nome — ver modules/cloud-run/main.tf).
  service_name = "backend-dev"
  image        = var.backend_image

  # Ambiente de dev: sem proteção contra destroy, permite scale-to-zero.
  deletion_protection   = false
  allow_unauthenticated = true

  # Libera CORS pras duas URLs válidas do frontend em dev (canônica + legada
  # por número do projeto, ver environments/prod/main.tf), mantendo o Vite
  # dev server local (localhost:5173) funcionando contra o backend de dev.
  env = {
    OBSERVABILITY_HUB_CORS_ORIGINS = "${module.frontend_cloud_run.service_url},${module.frontend_cloud_run.service_url_alt},http://localhost:5173"
    # Único sinal de ambiente do backend (core/config.py::settings.environment)
    # — nunca mais inferido do project_id, que é o mesmo pros dois ambientes
    # nesta topologia.
    OBSERVABILITY_HUB_ENVIRONMENT = "dev"
  }
}

module "frontend_cloud_run" {
  source = "../../modules/cloud-run"

  project_id   = var.project_id
  region       = var.region
  service_name = "frontend-dev"
  image        = var.frontend_image

  # Frontend estático (serve -s dist) não tem endpoint /health — a raiz
  # responde 200 e serve pros probes de startup/liveness.
  health_check_path = "/"

  # Reaproveita o repositório Artifact Registry criado pelo backend_cloud_run
  # deste ambiente, em vez de tentar criar um segundo "apps" — o mesmo repo
  # é compartilhado por backend-dev, frontend-dev, backend-prod e
  # frontend-prod (todos no mesmo projeto), ver environments/prod/main.tf.
  manage_artifact_registry = false

  # Ambiente de dev: sem proteção contra destroy, permite scale-to-zero.
  deletion_protection   = false
  allow_unauthenticated = true
}

# Firestore named database do ambiente dev — dev e prod estão no mesmo
# projeto GCP, então não dá pra usar o banco "(default)" implícito pros
# dois (misturaria dados). Precisa existir antes do primeiro deploy do
# backend (core/firestore.py::get_firestore_client usa database="dev").
resource "google_firestore_database" "hub" {
  project     = var.project_id
  name        = "dev"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  # Ambiente de dev: sem proteção, permite destroy/recriação sem fricção.
  delete_protection_state = "DELETE_PROTECTION_DISABLED"
  deletion_policy         = "DELETE"
}
