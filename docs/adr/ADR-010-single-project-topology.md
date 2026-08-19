# ADR-010 — Topologia single-project (dev e prod no mesmo projeto GCP)

**Status:** Aceito
**Data:** 2026-08-18

---

## Contexto

Este repositório é derivado de `observability-hub`, onde dev e prod
rodavam em dois projetos GCP totalmente separados
(`observability-hub-dev`, `observability-hub-prod` — ver
[ADR-0003](ADR-0003-terraform-diretorios-por-ambiente.md)). A empresa
cliente que hospeda esta cópia só autoriza a criação de **um único
projeto GCP** para esta aplicação — restrição permanente, não uma fase
transitória a ser revisitada depois. Isso invalida a premissa de
contexto do ADR-0003 ("dois ambientes GCP totalmente separados"), então
este ADR documenta a topologia adotada em seu lugar.

Rodar dev e prod no mesmo projeto quebra qualquer mecanismo que infira
o ambiente a partir do `project_id` (o valor passa a ser idêntico pros
dois) ou que dependa de nomes de recurso serem naturalmente únicos por
projeto (Cloud Run service, service account de runtime, banco Firestore
default, bucket de tfstate, pool/provider WIF).

## Decisão

Um único projeto GCP (`gcp-hub-dp6`, projeto piloto real deste
repositório) hospeda dev e prod lado a lado. O isolamento entre os dois
ambientes deixa de vir de fronteira de projeto e passa a vir
inteiramente de **convenção de nome sufixado por ambiente**, aplicada
em toda a stack:

- **Ambiente do backend**: explícito via `OBSERVABILITY_HUB_ENVIRONMENT`
  (injetado pelo Terraform), nunca mais inferido do `project_id` — ver
  `core/config.py::settings.environment`, `core/secrets.py::_is_prod`.
- **Cloud Run**: `service_name` sempre sufixado (`backend-dev`,
  `backend-prod`, idem frontend) — a SA de runtime herda o sufixo
  automaticamente (`account_id = "${service_name}-run"`).
- **Firestore**: named database por ambiente (`hub-dev`/`hub-prod` —
  prefixo `hub-` obrigatório porque `database_id` exige 4+ caracteres,
  "dev" sozinho é rejeitado pela API) em vez do banco `(default)`
  implícito, que seria compartilhado — ver `core/firestore.py`.
- **Secret Manager**: secrets com valor distinto por ambiente têm nome
  sufixado, inclusive `JWT_SECRET_DEV`/`_PROD` (sem o sufixo, seria
  literalmente o mesmo secret assinando sessão de dev e de prod — só
  `OAUTH_ALLOWLIST` é intencionalmente compartilhado).
- **Artifact Registry**: um único repositório `apps`, compartilhado
  pelos quatro serviços (backend/frontend × dev/prod) — só uma
  instância do módulo `cloud-run` o gerencia (`manage_artifact_registry`).
- **Bootstrap/WIF**: **um pool compartilhado, mas um provider por
  ambiente** (`github-provider-dev`/`github-provider-prod`) — a
  restrição "prod só via `refs/heads/main`" vive no
  `attribute_condition` do provider de prod, exatamente como no
  repositório de origem (um provider por ambiente já resolvia isso lá,
  só que com um pool também por ambiente). O binding de cada SA de
  deploy (`gh-deploy-{env}`) usa sempre o mesmo formato simples
  (`principalSet://.../attribute.repository/{repo}`, escopado ao pool,
  não ao provider) — ver "Notas do piloto" abaixo pra três tentativas
  alternativas que pareciam mais elegantes e não funcionaram.
- **Terraform state**: um bucket único, isolado só por `prefix`
  (`environments/dev`/`environments/prod`) — já era assim antes, não
  precisou mudar.

A estrutura de diretórios por ambiente decidida no ADR-0003
(`environments/dev`, `environments/prod` como raízes de execução
independentes, sem Terraform workspaces) **permanece inalterada** — o
que mudou foi só a premissa de que cada uma aponta para um projeto GCP
diferente.

## Alternativas consideradas

**Inferir o ambiente de alguma outra convenção de projeto (ex: label,
número de projeto)** — rejeitada: qualquer sinal derivado do projeto
sofre do mesmo problema estrutural (projeto é o mesmo pros dois
ambientes); um sinal explícito (env var injetada pelo Terraform) é a
única opção que não depende de heurística.

**Terraform workspaces para diferenciar dev/prod dentro do projeto
único** — rejeitada pelos mesmos motivos do ADR-0003: aumenta o risco
de aplicar no ambiente errado, e neste repositório o risco seria maior
ainda, já que os dois ambientes compartilham o mesmo projeto (sem nem a
barreira de "autenticado em outro projeto" como rede de segurança).

**Um único ambiente sem separação dev/prod** — rejeitada: perde a
capacidade de testar mudanças (deploy automático em qualquer push) sem
afetar produção; o gate de aprovação manual em prod (ver `CLAUDE.md`,
seção CI/CD) depende de dev e prod serem deploys de fato distintos.

## Consequências

- **Blast radius concentrado**: as duas SAs de deploy (`gh-deploy-dev`,
  `gh-deploy-prod`) têm os mesmos papéis de admin sobre o mesmo
  projeto — um bug ou vazamento de credencial em dev tem alcance
  administrativo sobre o projeto inteiro, incluindo prod. Não há
  fronteira de projeto como rede de segurança adicional; a mitigação é
  disciplina de nomenclatura + revisão de `terraform plan`, não
  isolamento estrutural.
- **Falha silenciosa se um sufixo for esquecido**: um recurso novo sem
  sufixo de ambiente correto (Cloud Run, Firestore, IAM binding) não dá
  erro de "já existe" necessariamente — pode silenciosamente misturar
  dev e prod (ex: os dois lendo o mesmo Firestore, ou uma SA de deploy
  reconfigurando o serviço errado). Checklist de revisão de `terraform
  plan` precisa verificar nomes de recurso, não só contagem de mudanças.
- **Custo e cota compartilhados**: billing e quotas de API (ex:
  BigQuery slots, requests/min) são do projeto inteiro, não por
  ambiente — um domínio com bug em dev consumindo cota agressivamente
  pode afetar prod.
- **Simplicidade de setup**: um único `gcloud projects create` e um
  único bootstrap Terraform, contra a alternativa de dois projetos —
  reduz o checklist de implantação em ambientes onde só um projeto é
  viável.

## Notas do piloto (`gcp-hub-dp6`, 2026-08-19)

Problemas reais encontrados na primeira aplicação real deste desenho,
registrados aqui porque não eram óbvios a partir da documentação do
Google e vale não repetir a investigação:

- **Bucket de state inacessível mesmo pro Owner do projeto.** O bucket
  criado pelo primeiro `terraform apply` do bootstrap ficou com
  `storage.buckets.get`/`getIamPolicy` negados pro Owner do projeto
  (`roles/owner`, sem condição), por mais de 7 minutos — não era
  propagação (um bucket novo criado manualmente no mesmo projeto, ao
  mesmo tempo, funcionou instantaneamente). Nunca identificada a causa
  raiz; resolvido apagando o bucket (vazio, sem uso ainda) e deixando o
  Terraform recriar. Isso também apagou as `google_storage_bucket_iam_member`
  daquele bucket, que o Terraform detectou como drift e recriou no
  apply seguinte.
- **`database_id` do Firestore exige 4+ caracteres.** `"dev"` (3
  caracteres) é rejeitado pela API (`prod` sozinho já seria válido, mas
  ficou `hub-prod` por consistência) — só descoberto no primeiro
  `terraform apply` real de `environments/dev`, não em `terraform
  validate`/`plan` (que não faz essa validação de formato).
- **Restringir a impersonação de uma SA por branch, com um provider
  WIF compartilhado entre ambientes, é mais frágil do que parece.**
  Três abordagens falharam, todas com o mesmo sintoma
  (`iam.serviceAccounts.getAccessToken denied`, testado via
  `terraform-apply-prod.yml` real, não simulação) antes da que
  funcionou:
  1. `principal://.../subject/repo:{org}/{repo}:ref:{ref}` (montando o
     claim `sub` manualmente) — sintaticamente aceito pelo Terraform,
     falha em runtime.
  2. `principalSet://.../attribute.ref/{ref}` com o valor
     url-encoded (`refs%2Fheads%2Fmain`) — mesmo sintoma; o valor do
     atributo não deve ser url-encoded (barra fica literal, mesmo
     padrão de `attribute.repository/{org}/{repo}`).
  3. IAM Condition (`condition { expression = "attribute.ref == ..." }`)
     no binding da SA — nem compila: `attribute.*` não existe no
     contexto de uma IAM Condition (que avalia atributos do *recurso*
     sendo acessado, não do principal federado que está fazendo a
     chamada) — erro claro de "undeclared reference to 'attribute'",
     o único das quatro tentativas com uma mensagem de erro realmente
     útil.
  4. **O que funcionou**: voltar ao padrão do repositório de origem —
     um provider por ambiente (cada um com seu próprio
     `attribute_condition`), só compartilhando o *pool*. Também exigiu
     uns 2-3 minutos de propagação depois de criar os providers novos
     (diferente de editar o binding de uma SA existente, que parece
     aplicar quase na hora) — vale esperar antes de concluir que uma
     mudança de provider não funcionou.
