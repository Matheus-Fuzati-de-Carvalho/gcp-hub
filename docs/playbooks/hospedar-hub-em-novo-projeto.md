# Playbook — Hospedar o Observability Hub em um novo projeto GCP

**Pergunta que este playbook responde:** "quero rodar minha própria cópia
do Hub — hospedagem e administração — num projeto GCP diferente do
`observability-hub` original. O que precisa ser feito, do zero, pra
outra pessoa replicar isto?"

Este repositório usa **topologia single-project**: dev e prod rodam
**no mesmo projeto GCP** — restrição permanente da empresa que hospeda
esta cópia (não uma fase transitória), documentada em
[ADR-010](../adr/ADR-010-single-project-topology.md). O isolamento entre
os dois ambientes vem inteiramente de nomes de recurso sufixados por
ambiente (Cloud Run, service accounts, Firestore, secrets), nunca de
fronteira de projeto.

Este é um playbook de **bootstrap único** — a maioria dos passos roda
uma vez e nunca mais. Depois de concluído, o dia a dia é só `git push`
(ver `CLAUDE.md`, "CI/CD e deploy").

Não confundir com o outro playbook,
[`liberar-projeto-para-o-hub.md`](liberar-projeto-para-o-hub.md) — aquele
é sobre liberar acesso a um projeto *que o Hub vai observar*; este é
sobre onde o Hub *em si* roda.

---

## 1. Visão geral do que vai existir no final

**Um único projeto GCP**, com:

- 4 serviços Cloud Run: `backend-dev`, `frontend-dev`, `backend-prod`,
  `frontend-prod`
- 1 repositório Artifact Registry (`apps`) compartilhado pelos quatro
- 4 service accounts de runtime, uma por serviço (`backend-dev-run`,
  `frontend-dev-run`, `backend-prod-run`, `frontend-prod-run`)
- Firestore (Native mode), **dois named databases** (`dev` e `prod`) —
  dado próprio do Hub: ACL de usuário×projeto, favoritos, histórico,
  login events. Nunca o banco `(default)` implícito, que seria
  compartilhado entre os dois ambientes.
- Secret Manager — credenciais OAuth, JWT, allowlist de login
- Workload Identity Federation — **um pool/provider único**, compartilhado
  por duas service accounts de deploy (`gh-deploy-dev`, `gh-deploy-prod`)
- 1 bucket GCS de remote state do Terraform, isolado por `prefix`
  (`environments/dev`/`environments/prod`)

```
GitHub (push) → GitHub Actions (WIF, sem chave) → Terraform apply
                                                  → build + push imagem
                                                  → gcloud run deploy
```

`dev` recebe push de qualquer branch exceto `main`; `prod` recebe
push/merge em `main` (ver `CLAUDE.md`, "CI/CD e deploy").

---

## 2. Pré-requisitos

- `gcloud` CLI instalado e autenticado (`gcloud auth login` +
  `gcloud auth application-default login`) com uma conta que seja Owner
  (ou papéis equivalentes: Project IAM Admin, Service Usage Admin,
  Storage Admin, Workload Identity Pool Admin, Service Account Admin) —
  vai criar o projeto do zero.
- Terraform `>= 1.7` (o pipeline usa `1.9.8`, ver `.github/workflows/`).
- Uma conta de billing do GCP para vincular ao projeto novo.
- Um repositório GitHub próprio (fork ou cópia deste repo) — o WIF é
  restrito a `owner/repo` exato, então o valor precisa ser o do seu
  repositório, não o original.
- `gh` CLI autenticado nesse repositório (só necessário se for usar os
  comandos `gh secret set` abaixo — pode ser feito pela UI do GitHub também).

---

## 3. Escolher o nome do projeto

Este repositório, como está hoje, **hardcoda** `observability-hub` em
vários lugares (não é parametrizado via `.tfvars` em CI — os
`terraform.tfvars.example` existem só como referência para apply manual
local). Escolha o `project_id` novo agora — todo o restante deste
playbook assume que você já decidiu o nome (ex: `acme-hub`) e vai
substituí-lo consistentemente nos arquivos listados no passo 6.

> ℹ️ **Diferente do repositório de origem, o nome do projeto NÃO
> precisa terminar em `-dev`/`-prod`** — esse requisito existia porque
> `core/secrets.py::_is_prod()` inferia o ambiente do sufixo do
> `project_id`. Neste repositório o ambiente é sempre explícito
> (`OBSERVABILITY_HUB_ENVIRONMENT`, injetada pelo Terraform — ver
> ADR-010), então o nome do projeto pode ser qualquer coisa válida pro
> GCP (ex: `acme-hub`, sem sufixo nenhum — dev e prod são o mesmo
> projeto de qualquer forma).

---

## 4. Criar o projeto GCP e vincular billing

```bash
gcloud projects create {NOVO_PROJETO} --name="Observability Hub"

gcloud billing projects link {NOVO_PROJETO} --billing-account={BILLING_ACCOUNT_ID}
```

`{BILLING_ACCOUNT_ID}` — descubra com `gcloud billing accounts list`.

---

## 5. Habilitar e provisionar o Firestore (passo manual — não é Terraform hoje)

O Firestore em si (a habilitação da API) é provisionado manualmente,
mas os **dois named databases** (`dev` e `prod`) já são criados pelo
Terraform via `google_firestore_database` em cada
`environments/{dev,prod}/main.tf` — não precisa criá-los aqui, só
habilitar a API antes do primeiro `terraform apply` (passo 9):

```bash
gcloud services enable firestore.googleapis.com --project={PROJETO}
```

Se preferir criar os bancos manualmente antes/fora do Terraform (ex:
pra testar algo isolado), o comando equivalente é:

```bash
gcloud firestore databases create \
  --project={PROJETO} \
  --database={dev|prod} \
  --location={REGIAO_FIRESTORE} \
  --type=firestore-native
```

`{REGIAO_FIRESTORE}` precisa ser uma
[localização Firestore válida](https://cloud.google.com/firestore/docs/locations)
— `us-central1` funciona como região regular (o mesmo valor usado como
`region` no resto deste playbook).

---

## 6. Ajustar os defaults do repositório para o novo projeto

Edite estes arquivos, trocando `observability-hub` pelo nome escolhido
no passo 3 (e o `github_repository` pelo seu `owner/repo`):

| Arquivo | O que trocar |
|---|---|
| `infra/terraform/bootstrap/variables.tf` | `default` de `project_id`, `default` de `github_repository` |
| `infra/terraform/environments/dev/variables.tf` | `default` de `project_id` |
| `infra/terraform/environments/prod/variables.tf` | `default` de `project_id` (**mesmo valor** do de dev — é o mesmo projeto) |
| `infra/terraform/environments/dev/versions.tf` | `backend "gcs" { bucket = "..." }` → `{NOVO_PROJETO}-tfstate` |
| `infra/terraform/environments/prod/versions.tf` | idem, **mesmo bucket** (`{NOVO_PROJETO}-tfstate`) — só o `prefix` já diferencia dev de prod |
| `.github/workflows/backend-deploy-dev.yml` | `env.PROJECT_ID` |
| `.github/workflows/backend-deploy-prod.yml` | `env.PROJECT_ID` (**mesmo valor** do de dev) |
| `.github/workflows/frontend-deploy-dev.yml` | `env.PROJECT_ID` |
| `.github/workflows/frontend-deploy-prod.yml` | `env.PROJECT_ID` (**mesmo valor** do de dev) |

O nome do bucket de state (`versions.tf`) precisa bater exatamente com o
que o bootstrap vai criar no passo 7 (`<project_id>-tfstate`, ver
`infra/terraform/bootstrap/modules/wif-bootstrap/main.tf`).
`docs/onboarding-cliente.md` também cita o `project_id` original como
exemplo — não é funcional, mas vale revisar depois pra não confundir
quem ler.

---

## 7. Bootstrap do Terraform (uma única vez, fora do CI)

Já documentado em detalhe em
[`infra/terraform/bootstrap/README.md`](../../infra/terraform/bootstrap/README.md)
— resumo aqui, siga o README para o passo a passo completo:

```bash
cd infra/terraform/bootstrap
terraform init
terraform plan
terraform apply
```

Isso cria, no projeto: bucket de state, as APIs base habilitadas
(`iam`, `run`, `artifactregistry`, `bigquery`, `secretmanager`,
`logging`, `firestore`, etc. — lista completa em
`infra/terraform/bootstrap/modules/wif-bootstrap/main.tf`), um único
pool/provider de Workload Identity Federation, e **duas** service
accounts de deploy (`gh-deploy-dev`, `gh-deploy-prod`) — uma única
execução, não uma por ambiente.

**Guarde o `terraform.tfstate` local deste diretório fora do Git**
(não é versionado, é a única cópia) — o README já avisa, reforçando
aqui porque é fácil perder numa máquina descartável.

Ao final, capture os três outputs:

```bash
terraform output state_bucket_name
terraform output workload_identity_provider
terraform output -json service_account_emails
```

`service_account_emails` é um mapa `{ "dev": "...", "prod": "..." }` —
os dois deploys de app usam o mesmo `workload_identity_provider`, mas
cada um usa a entrada correspondente do mapa.

---

## 8. Configurar os secrets do GitHub Actions e o gate de aprovação de prod

Quatro secrets no repositório (Settings → Secrets and variables →
Actions), usando os outputs do passo 7:

```bash
WIF_PROVIDER=$(terraform -chdir=infra/terraform/bootstrap output -raw workload_identity_provider)
WIF_SA_DEV=$(terraform -chdir=infra/terraform/bootstrap output -json service_account_emails | jq -r .dev)
WIF_SA_PROD=$(terraform -chdir=infra/terraform/bootstrap output -json service_account_emails | jq -r .prod)

# WIF_PROVIDER_DEV e WIF_PROVIDER_PROD recebem o MESMO valor — é um único
# pool/provider compartilhado (ver ADR-010); só a SA impersonada muda.
gh secret set WIF_PROVIDER_DEV --body "$WIF_PROVIDER"
gh secret set WIF_PROVIDER_PROD --body "$WIF_PROVIDER"
gh secret set WIF_SA_DEV --body "$WIF_SA_DEV"
gh secret set WIF_SA_PROD --body "$WIF_SA_PROD"
```

Sem isso, todo workflow falha no primeiro passo (`google-github-actions/auth`).

### 8.1 Gate de aprovação manual em prod (não é opcional — os workflows já esperam por ele)

`backend-deploy-prod.yml` e `frontend-deploy-prod.yml` declaram
`environment: production` no job de deploy (ver `CLAUDE.md`, "CI/CD e
deploy") — deploy de app em prod não roda sozinho a cada push em
`main`, ele fica **parado em "Waiting"** até alguém aprovar. Isso é só
metade da configuração: o outro lado é um **GitHub Environment** chamado
exatamente `production`, com "required reviewers", que precisa ser
criado nas *Settings* deste novo repositório (não é algo que o Terraform
ou o código gerencia):

1. **Settings → Environments → New environment**
2. Nome: **`production`** (exatamente esse nome — é o que os workflows
   referenciam)
3. Marque **"Required reviewers"** e adicione quem deve aprovar deploys
   de prod
4. Save protection rules

Se você pular este passo, os workflows continuam funcionando — só que
**sem gate nenhum**: `environment: production` sem uma regra de proteção
configurada não bloqueia nada, o job roda direto. `terraform-apply-
prod.yml` (aplica infra) continua automático de propósito, mesmo com
esse gate configurado — só os dois deploys de app são afetados (decisão
consciente, ver `CLAUDE.md`).

---

## 9. Primeiro apply do Terraform de cada ambiente

Com os arquivos do passo 6 já commitados, dê push numa branch qualquer
(não `main`) tocando `infra/terraform/environments/dev/**` — isso
dispara `terraform-apply-dev.yml` automaticamente. Confirme que rodou
com sucesso (`gh run list --workflow=terraform-apply-dev.yml`) antes de
seguir — ele cria `backend-dev`, `frontend-dev`, o repositório Artifact
Registry `apps` (só a instância de dev o gerencia — ver
`manage_artifact_registry` nos root modules), o Firestore database
`dev` e as duas service accounts de runtime de dev.

Para prod, o mesmo `terraform apply` só roda em push/merge para `main` —
deixe para depois de validar tudo em dev (passo 15). Ele reaproveita o
mesmo repositório Artifact Registry (`manage_artifact_registry = false`
nos dois módulos de prod) e cria só o que é exclusivo de prod: os dois
serviços Cloud Run `-prod`, o Firestore database `prod`.

Alternativa manual (se preferir não depender do primeiro push para
isso): `cd infra/terraform/environments/dev && terraform init && terraform apply`,
autenticado com as mesmas credenciais de Owner do passo 2.

---

## 10. Conceder as roles manuais às service accounts de runtime do backend

O módulo `cloud-run` cria as service accounts (`backend-dev-run@{projeto}...`,
`backend-prod-run@{projeto}...`) mas **não concede nenhuma role própria**
ainda (comentário no próprio `main.tf` do módulo: "hoje sem papéis
próprios"). Sem isso, o backend sobe mas todo endpoint que toca
Firestore ou Secret Manager falha em runtime. Rode para **cada** uma das
duas service accounts de backend (dev e prod, mesmo projeto):

```bash
for ENV in dev prod; do
  SA_EMAIL="backend-${ENV}-run@{PROJETO}.iam.gserviceaccount.com"

  gcloud projects add-iam-policy-binding {PROJETO} \
    --member="serviceAccount:${SA_EMAIL}" --role="roles/datastore.user"

  gcloud projects add-iam-policy-binding {PROJETO} \
    --member="serviceAccount:${SA_EMAIL}" --role="roles/secretmanager.secretAccessor"
done
```

`roles/datastore.user` é concedido a nível de projeto, não por banco —
tecnicamente `backend-dev-run` também consegue acessar o database
`prod` do Firestore (e vice-versa). O isolamento real vem do código
(`core/firestore.py` sempre usa `database=settings.environment`, nunca
o outro), não de uma barreira de IAM — ver ADR-010, seção
"Consequências", sobre esse blast radius compartilhado ser uma
característica da topologia, não um descuido.

Essas duas roles são **só no próprio projeto** — nunca pedidas a um
projeto alvo (ver `docs/onboarding-cliente.md`, "O que NÃO é necessário").

---

## 11. Configurar o OAuth Client no Google Cloud Console

O login usa Google OAuth (`domains/auth`), escopo `openid email profile`
— não é um escopo sensível, então não precisa de revisão de verificação
do Google mesmo publicando a tela de consentimento como "Externo/Em
produção".

1. **APIs & Services → OAuth consent screen**: crie a tela (tipo Interno
   se seu Google Workspace cobrir todos os usuários esperados; Externo
   caso contrário — publique como "Em produção" para não cair no limite
   de 100 usuários de teste). Escopos: `openid`, `email`, `profile`.
2. **APIs & Services → Credentials → Create Credentials → OAuth client
   ID**, tipo "Web application", um client por ambiente (dev e prod usam
   client IDs diferentes — `secrets.py` já espera isso, ver passo 12).
3. **Authorized redirect URIs** — a URL do **frontend** (não do backend)
   + `/auth/callback`. Pegue as duas URLs válidas do serviço criado no
   passo 9:
   ```bash
   gcloud run services describe frontend-dev --project={PROJETO} --region={REGIAO} \
     --format='value(status.url)'
   gcloud run services describe frontend-prod --project={PROJETO} --region={REGIAO} \
     --format='value(status.url)'
   ```
   mais a URL alternativa por número do projeto (ver output
   `service_url_alt` do módulo `cloud-run`,
   `https://frontend-{env}-{numero_do_projeto}.{regiao}.run.app`).
   Cadastre as duas, para dev e para prod (4 URIs no total, 2 por client).
4. Anote o **Client ID** e o **Client Secret** gerados — vão para o
   Secret Manager no próximo passo.

---

## 12. Criar os secrets no Secret Manager

Sete secrets, **todos no mesmo projeto** (topologia single-project):

```bash
echo -n "{CLIENT_ID_DEV}"     | gcloud secrets create GOOGLE_OAUTH_CLIENT_ID_DEV --data-file=- --project={PROJETO}
echo -n "{CLIENT_SECRET_DEV}" | gcloud secrets create GOOGLE_OAUTH_CLIENT_SECRET_DEV --data-file=- --project={PROJETO}
echo -n "{JWT_SECRET_DEV_ALEATORIO}" | gcloud secrets create JWT_SECRET_DEV --data-file=- --project={PROJETO}

echo -n "{CLIENT_ID_PROD}"     | gcloud secrets create GOOGLE_OAUTH_CLIENT_ID_PROD --data-file=- --project={PROJETO}
echo -n "{CLIENT_SECRET_PROD}" | gcloud secrets create GOOGLE_OAUTH_CLIENT_SECRET_PROD --data-file=- --project={PROJETO}
echo -n "{JWT_SECRET_PROD_ALEATORIO_DIFERENTE}" | gcloud secrets create JWT_SECRET_PROD --data-file=- --project={PROJETO}

# único secret compartilhado de propósito entre os dois ambientes —
# controla só quem pode logar, não isolamento de sessão (ver core/secrets.py)
echo -n '{"allowed_domains": ["seudominio.com"], "allowed_emails": []}' \
  | gcloud secrets create OAUTH_ALLOWLIST --data-file=- --project={PROJETO}
```

Notas:
- `JWT_SECRET_DEV`/`JWT_SECRET_PROD`: gere um valor aleatório longo por
  ambiente (ex: `openssl rand -hex 32`) — **precisam ser valores
  diferentes**. Diferente de antes (dois projetos, mesmo nome de
  secret), aqui os dois nomes já são diferentes por construção — não
  tem como criar os dois com o mesmo nome sem sobrescrever um pelo
  outro, mas é fácil copiar/colar o mesmo *valor* nos dois por engano.
  Não faça isso: um token de sessão de dev validaria em prod.
- `OAUTH_ALLOWLIST` é quem entra no Hub (login), não quem acessa qual
  projeto — controla só a barreira inicial. Ajuste `allowed_domains`/
  `allowed_emails` para a realidade de quem vai usar o Hub.
- `secrets.py` lê sempre a versão `latest`, cacheada por processo
  (`lru_cache`) — atualizar um secret exige reiniciar as instâncias do
  Cloud Run (ou aguardar novo deploy/scale) para o valor novo valer.
- Nenhum desses secrets é gerenciado por Terraform hoje
  (`infra/terraform/modules/secret-manager/` ainda é um módulo vazio) —
  são só os `gcloud secrets create` acima, manuais.

---

## 13. Deploy real do backend e frontend

Os workflows `backend-deploy-dev.yml`/`frontend-deploy-dev.yml` só têm
gatilho `on: push` filtrado por path (`apps/backend/**`/`apps/frontend/**`)
— sem `workflow_dispatch`, não dá para disparar manualmente pela UI/`gh
workflow run`. Se o push do passo 9 alterou só os arquivos de
`infra/terraform/**` (caso comum ao replicar: você editou só os 9
arquivos do passo 6, sem tocar código de app), esses dois workflows
**não disparam sozinhos**. Garanta que eles rodem pelo menos uma vez —
o jeito mais simples é incluir qualquer alteração trivial em
`apps/backend/**`/`apps/frontend/**` no mesmo push (ou num push logo
em seguida), nem que seja um comentário.

Quando disparam, eles buildam a imagem, dão push no Artifact Registry e
rodam `gcloud run deploy --image ...`. O frontend builda com
`VITE_API_BASE_URL` apontando pra URL real do backend, descoberta em
runtime do workflow via `gcloud run services describe backend-dev`
(ou `-prod`) — não precisa configurar isso manualmente.

Confirme:

```bash
gh run list --workflow=backend-deploy-dev.yml --limit=1
gh run list --workflow=frontend-deploy-dev.yml --limit=1
```

---

## 14. Bootstrap do primeiro administrador

Sem isso, `hub_users` fica vazio (no banco Firestore do ambiente
correspondente) e ninguém consegue abrir `/admin` — nem `require_admin`
nem `require_project_access` liberam nada sem documento existente (fail
closed por design). Rode localmente, com suas credenciais de operador
(não a service account de runtime):

```bash
gcloud auth application-default login   # se ainda não tiver feito

cd apps/backend
uv run python ../../scripts/seed_admin.py \
  --project {PROJETO} --environment dev --email {seu-email-admin}
```

`--environment` é obrigatório e não é cosmético: dev e prod são
**named databases distintos** dentro do mesmo projeto Firestore
(`--database=dev`/`--database=prod` internamente) — rodar sem o
ambiente certo escreve num banco que ninguém lê.

Rode em dev primeiro, valide o fluxo ponta a ponta, só depois repita
com `--environment prod` (mesmo `--project`).

---

## 15. Validar ponta a ponta (dev)

1. Abra a URL do frontend de dev no navegador.
2. Clique em "Entrar com Google", autentique com um e-mail coberto pelo
   `OAUTH_ALLOWLIST` do passo 12.
3. Confirme que o login completa (senão, ver Troubleshooting abaixo).
4. Se o e-mail usado foi o mesmo do `seed_admin.py` (passo 14), confirme
   que o link/ícone de administrador aparece e `/admin` abre.
5. Digite um `project_id` no seletor — nesse ponto, nenhum projeto alvo
   foi liberado ainda (isso é o outro playbook,
   [`liberar-projeto-para-o-hub.md`](liberar-projeto-para-o-hub.md)), então
   espera-se um erro `ProjectNotAuthorizedError`/`ProjectAccessDeniedError`
   — é o sinal de que a stack está de pé e o gate de ACL está funcionando.

---

## 16. Repetir para prod

Depois de validar dev:

1. Merge/push da branch com os arquivos do passo 6 para `main` — dispara
   `terraform-apply-prod.yml` (cria os serviços Cloud Run de prod e o
   Firestore database `prod`, automático) e, em seguida,
   `backend-deploy-prod.yml`/`frontend-deploy-prod.yml`.
2. **Os dois deploys de app ficam em "Waiting"** se o passo 8.1 foi
   configurado — abra a aba *Actions* do repositório, clique no run
   parado, **Review deployments → Approve and deploy**. Sem isso os dois
   jobs nunca terminam (não é erro, é o gate funcionando).
3. Repita os passos 10 (roles manuais — se já rodou o loop `for ENV in
   dev prod` do passo 10, isso já está feito), 11 (OAuth client de prod
   — client **separado** do de dev) e 14 (seed do primeiro admin,
   `--environment prod`). O passo 12 (secrets `_PROD`) provavelmente já
   foi feito junto com dev, já que os dois vivem no mesmo projeto.
4. Repita a validação do passo 15 na URL de prod.

---

## 17. Depois de hospedado

O Hub está de pé, mas ainda não observa nenhum dado — ele só enxerga
projetos GCP explicitamente liberados. Para cada projeto que ele deve
observar (incluindo, se quiser, o próprio `{PROJETO}` servindo de alvo
dele mesmo), siga [`liberar-projeto-para-o-hub.md`](liberar-projeto-para-o-hub.md).

---

## Checklist final

```
[ ] project_id único escolhido (não precisa terminar em "-dev"/"-prod"
    neste repositório — ver passo 3)
[ ] Projeto GCP criado e billing vinculado
[ ] API do Firestore habilitada no projeto
[ ] Arquivos do passo 6 editados e commitados (project_id x2, bucket de
    state x2, github_repository, PROJECT_ID dos 4 workflows — todos
    apontando pro mesmo projeto/bucket)
[ ] Bootstrap Terraform aplicado manualmente, uma única vez — outputs
    capturados (state_bucket_name, workload_identity_provider,
    service_account_emails)
[ ] 4 secrets do GitHub Actions configurados (WIF_PROVIDER_DEV/PROD —
    mesmo valor nos dois —, WIF_SA_DEV/PROD — valores diferentes)
[ ] Environment "production" criado nas Settings do GitHub com
    required reviewers (passo 8.1) — sem isso os deploys de app em prod
    não têm gate nenhum
[ ] Primeiro apply de environments/dev confirmado com sucesso (cria
    backend-dev, frontend-dev, repo apps, Firestore database "dev")
[ ] roles/datastore.user + roles/secretmanager.secretAccessor
    concedidas às DUAS service accounts de backend (backend-dev-run,
    backend-prod-run)
[ ] OAuth consent screen + OAuth Client (dev e prod, client IDs
    diferentes) configurados com os redirect URIs corretos
[ ] 7 secrets criados no Secret Manager (GOOGLE_OAUTH_CLIENT_ID/SECRET
    _DEV/_PROD, JWT_SECRET_DEV/JWT_SECRET_PROD com valores DIFERENTES,
    OAUTH_ALLOWLIST compartilhado)
[ ] Deploy de backend e frontend confirmado (dev)
[ ] Primeiro admin criado via scripts/seed_admin.py --environment dev
[ ] Login + /admin validados ponta a ponta em dev
[ ] Passos 9–14 repetidos para prod (Terraform apply de prod cria
    backend-prod, frontend-prod, Firestore database "prod")
[ ] Deploys de app em prod aprovados manualmente (Review deployments),
    se o gate do passo 8.1 estiver configurado
[ ] Primeiro admin criado via scripts/seed_admin.py --environment prod
[ ] Login + /admin validados ponta a ponta em prod
```

---

## Troubleshooting

Baseado em incidentes reais já registrados em `CHANGELOG.md` (Fase 1) e
na migração pra topologia single-project (ADR-010):

| Sintoma | Causa | Correção |
|---|---|---|
| `terraform apply` do bootstrap falha criando uma SA de runtime (`iam.serviceAccounts.create denied`) | Faltou `roles/iam.serviceAccountAdmin` na SA de deploy | Já corrigido no módulo `wif-bootstrap` deste repo — se você clonou uma versão anterior, adicione a role manualmente à `gh-deploy-{env}` e reaplique o bootstrap |
| `terraform apply` do bootstrap falha criando o Firestore database (`datastore.owner` denied) | Faltou `roles/datastore.owner` na SA de deploy | Já corrigido no módulo `wif-bootstrap` deste repo (ver `bootstrap/README.md`) |
| Cloud Run criado "fora do state" do Terraform, com a SA default do Compute Engine em vez da SA de runtime esperada | `terraform-apply-*.yml` e `*-deploy-*.yml` rodaram em paralelo no mesmo push, e o deploy criou o serviço antes do Terraform | Os workflows deste repo já têm `wait-for-terraform` para isso — não remova esse job ao adaptar os workflows |
| Drift entre o Cloud Run real e o state do Terraform | Consequência do item acima, se já tiver acontecido | Em ambiente sem tráfego real: `gcloud run services delete` seguido de `terraform apply`. Com tráfego real, preferir `terraform import` |
| Provider `google` falha no primeiro `terraform apply` do bootstrap reclamando de Service Usage/Resource Manager API desabilitada | Em alguns projetos novíssimos essas duas não vêm habilitadas por padrão | `gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com --project={PROJETO}` antes do primeiro apply |
| `terraform apply` de `environments/prod` falha tentando criar o repositório Artifact Registry `apps` (já existe) | `manage_artifact_registry` não está `false` nos dois módulos de prod (backend e frontend) — só a instância de dev deve gerenciar o repo compartilhado | Conferir `environments/prod/main.tf` — os dois `module` blocks precisam de `manage_artifact_registry = false` |
| Backend sobe mas todo endpoint autenticado falha (`/auth/me`, favoritos, admin) | Passo 10 (roles `datastore.user`/`secretmanager.secretAccessor`) não foi feito pra aquela SA específica (dev e prod são SAs diferentes, precisam das duas concessões cada) | Conceder as duas roles à `backend-{env}-run@{projeto}` correspondente |
| Login falha na troca do código OAuth | Redirect URI cadastrado no Google Console não bate com a URL real do frontend (`frontend-dev`/`frontend-prod`), ou o secret errado | Conferir passo 11 (as 2 URLs por ambiente) e que o ambiente lê o par de secrets com o sufixo certo |
| `/admin` não abre para ninguém num ambiente específico | `scripts/seed_admin.py` (passo 14) não foi rodado com o `--environment` certo | Rodar o script apontando pro `--environment` certo (dev ou prod) — lembre que são bancos Firestore diferentes, não é redundante rodar duas vezes |
| Um token de sessão válido em dev também funciona em prod (ou vice-versa) | `JWT_SECRET_DEV` e `JWT_SECRET_PROD` foram criados com o **mesmo valor** por engano (nomes diferentes, mas alguém colou o mesmo texto nos dois) | Gerar dois valores aleatórios de fato distintos e recriar os secrets (`gcloud secrets versions add`) |
| Deploy de app em prod nunca termina, fica "Waiting" indefinidamente no Actions | Gate de aprovação do passo 8.1 configurado, mas ninguém aprovou ainda | Abrir o run → Review deployments → Approve and deploy (é o comportamento esperado, não é erro) |
| Deploy de app em prod roda sozinho, sem pedir aprovação, mesmo tendo criado o environment "production" | Nome do environment não é exatamente `production`, ou "Required reviewers" não foi marcado nas Settings | Revisar passo 8.1 — o nome precisa bater com `environment: production` do YAML |

---

## Referências

- `CLAUDE.md` — convenções gerais, estrutura de pastas, CI/CD, seção
  "Projetos e ambientes GCP"
- [ADR-0002 — GCP como cloud provider](../adr/ADR-0002-gcp-como-cloud-provider.md)
- [ADR-0003 — Terraform por diretório de ambiente](../adr/ADR-0003-terraform-diretorios-por-ambiente.md)
- [ADR-0004 — Workload Identity Federation](../adr/ADR-0004-workload-identity-federation.md)
- [ADR-009 — ACL de usuário × projeto](../adr/ADR-009-acl-usuario-projeto.md)
- [ADR-010 — Topologia single-project](../adr/ADR-010-single-project-topology.md)
- [`infra/terraform/bootstrap/README.md`](../../infra/terraform/bootstrap/README.md)
- [`docs/specs/admin.md`](../specs/admin.md) — bootstrap do primeiro admin, casos de borda do ACL
- `CHANGELOG.md`, seção "Fase 1" — incidentes reais do bootstrap original
