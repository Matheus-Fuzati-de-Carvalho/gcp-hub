# Bootstrap

Cria a fundação que o resto do Terraform (`infra/terraform/environments/`) e o GitHub Actions precisam para existir. Topologia single-project deste repositório: dev e prod rodam no **mesmo** projeto GCP, então o bootstrap roda **uma única vez**, não uma vez por ambiente:

- Bucket GCS de remote state, único, compartilhado (`<project_id>-tfstate`) — dev e prod se isolam dentro dele via `prefix` (`environments/dev` / `environments/prod`)
- APIs do GCP necessárias habilitadas no projeto
- Um Workload Identity Pool + Provider OIDC confiando no GitHub Actions, compartilhado pelos dois ambientes
- Duas service accounts de deploy, restritas ao repositório configurado em `github_repository`:
  - `gh-deploy-dev`: qualquer branch pode assumir a identidade
  - `gh-deploy-prod`: só a branch `main` pode assumir a identidade (restrição aplicada no IAM binding da SA, não no provider — um provider só não comporta duas condições de ref diferentes)

Aplicado **manualmente, fora do CI**, uma única vez — é o único ponto do projeto com state local (não há ainda um bucket remoto para guardar o próprio state do bootstrap).

## Pré-requisitos

- `gcloud auth application-default login` feito com uma conta que tenha permissão de Owner (ou papéis equivalentes: Project IAM Admin, Service Usage Admin, Storage Admin, Workload Identity Pool Admin, Service Account Admin) no projeto.
- Faturamento habilitado no projeto GCP.

## Aplicar

```bash
cd infra/terraform/bootstrap
terraform init
terraform plan
terraform apply
```

## Depois de aplicar

```bash
terraform output state_bucket_name
terraform output workload_identity_provider
terraform output service_account_emails
```

- `state_bucket_name` → vai no bloco `backend "gcs"` de **cada** `infra/terraform/environments/<env>` (mesmo bucket, `prefix` diferente).
- `workload_identity_provider` → vai no input `workload_identity_provider` da action `google-github-actions/auth`, igual nos workflows de dev e de prod.
- `service_account_emails` → um mapa `{ dev = "...", prod = "..." }`; cada workflow usa a entrada correspondente ao seu ambiente no input `service_account` de `google-github-actions/auth`.

## Importante

- `terraform.tfstate` local deste diretório **não é versionado** (está no `.gitignore` do repo) e é a única cópia do state do bootstrap. Faça um backup dele fora do Git (ex: gerenciador de segredos, bucket privado separado) — sem ele, o Terraform perde o rastro dos recursos já criados e uma reaplicação pode tentar recriar algo que já existe.
- `.terraform.lock.hcl` **é** versionado (mesmo espírito do `uv.lock`/`pnpm-lock.yaml`): trava a versão do provider `google` para reprodutibilidade.
- O bucket de state tem `prevent_destroy = true`: `terraform destroy` neste módulo não vai apagá-lo por engano.
- Os papéis concedidos às service accounts de deploy (`locals.deployer_roles` em `modules/wif-bootstrap/main.tf`) cobrem os módulos já planejados (`cloud-run`, `artifact-registry`, `bigquery`, `secret-manager`, `logging-sink`) mais `roles/datastore.owner` (Firestore, ver `google_firestore_database` em `environments/{dev,prod}/main.tf`). Revisite essa lista à medida que novos módulos forem escritos — em especial `roles/iam.serviceAccountUser`, hoje concedido a nível de projeto porque as service accounts de runtime do Cloud Run ainda não existem antes do primeiro apply; assim que existirem, vale restringir esse papel só a elas.
- As duas service accounts de deploy (`gh-deploy-dev`, `gh-deploy-prod`) têm os mesmos papéis de projeto e o mesmo projeto — isso concentra o "blast radius" administrativo dos dois ambientes num lugar só. É uma característica da topologia single-project (a empresa cliente só autoriza um projeto GCP para o Hub), não um descuido: o isolamento entre dev e prod vem de nomes de recurso sufixados por ambiente em todo o resto do Terraform (Cloud Run, SA de runtime, Firestore), não de fronteira de projeto.
