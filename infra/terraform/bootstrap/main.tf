module "bootstrap" {
  source = "./modules/wif-bootstrap"

  project_id        = var.project_id
  region            = var.region
  github_repository = var.github_repository

  # Uma única execução deste bootstrap cria as identidades de deploy dos
  # dois ambientes, já que dev e prod compartilham o mesmo projeto GCP
  # (topologia single-project). "dev" pode ser assumida por qualquer
  # branch (push em qualquer branch -> deploy em dev, CLAUDE.md); "prod"
  # só pela branch main (merge em main -> deploy em prod).
  deploy_identities = {
    dev = {
      restrict_to_ref = null
    }
    prod = {
      restrict_to_ref = "refs/heads/main"
    }
  }
}
