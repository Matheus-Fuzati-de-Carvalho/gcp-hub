# Observability Hub — Manual de Implementação

**Hospedagem em ambiente Google Cloud próprio**

---

## Sobre este manual

Este documento orienta a implementação de uma instância própria do
Observability Hub no seu ambiente Google Cloud — hospedagem e
administração completas sob seu controle.

Esta versão da aplicação usa **um único projeto Google Cloud** para os
dois ambientes (teste e produção) — não dois projetos separados. É uma
adaptação intencional para organizações que só autorizam a criação de
um projeto para esta aplicação; o isolamento entre teste e produção
continua garantido, só que por convenção de nomenclatura dentro do
mesmo projeto em vez de por fronteira de projeto.

**Quem deve executar:** um responsável técnico com papel de
*Owner* (ou equivalente) no Google Cloud e acesso ao repositório de
código da aplicação.

**Tempo estimado:** meio dia de trabalho técnico, considerando a
validação de cada etapa antes de avançar para a próxima.

---

## Segurança e escopo — o que este processo faz (e o que não faz)

- **Tudo acontece dentro do seu próprio projeto Google Cloud**, sob seu
  faturamento e sob seu controle total. Nenhum recurso é criado fora do
  que está descrito neste manual.
- **Nenhuma credencial de longa duração é criada ou armazenada.** A
  autenticação entre o GitHub e o Google Cloud usa *Workload Identity
  Federation* — o GitHub troca um token temporário por uma credencial do
  Google válida por poucos minutos, a cada execução. Não existe "senha"
  ou chave salva em segredo nenhum.
- **Permissões mínimas necessárias**, sempre restritas ao projeto que
  você mesmo cria neste processo — nunca a nenhum outro recurso da sua
  organização.
- **Processo reversível.** Apagar o projeto ao final remove tudo o que
  foi criado, sem deixar rastro em nenhum outro sistema.
- **Nenhum dado seu trafega para fora do seu ambiente Google Cloud** como
  parte deste processo — a hospedagem é inteiramente sua.
- **Auditável de ponta a ponta.** A infraestrutura é definida como código
  (Terraform) — cada recurso que será criado pode ser revisado antes de
  ser aplicado, e cada comando deste manual é explicado antes de ser
  executado.

---

## Visão geral

Ao final deste processo, você terá dois ambientes independentes (teste e
produção) rodando **no mesmo projeto Google Cloud**, com:

- Quatro aplicações web rodando em Cloud Run — backend (API) e frontend
  (interface), um par por ambiente
- Dois bancos de dados Firestore, um por ambiente, para preferências e
  controle de acesso interno da aplicação — mantidos separados dentro
  do mesmo projeto
- Um cofre de credenciais (Secret Manager) para as chaves de login, com
  entradas próprias por ambiente
- Autenticação do GitHub para o Google Cloud sem nenhuma chave estática

```
Repositório de código  →  Pipeline de implantação  →  Aplicação no ar
      (GitHub)               (sem credenciais fixas)      (Cloud Run)
```

O ambiente de **teste** recebe atualizações a cada alteração de código;
o ambiente de **produção**, só quando uma alteração é formalmente
aprovada e publicada.

---

## Antes de começar

- Acesso ao Google Cloud com papel de *Owner* (ou os papéis
  equivalentes: Administrador de IAM do Projeto, Administrador de Uso de
  Serviços, Administrador de Storage, Administrador de Workload Identity
  Pool, Administrador de Service Account).
- Uma conta de faturamento (billing) do Google Cloud disponível para
  vincular ao projeto novo.
- O Terraform instalado (versão 1.7 ou superior).
- Uma cópia do repositório de código da aplicação sob seu próprio
  controle (fork ou cópia direta), já que alguns arquivos de
  configuração precisam ser ajustados com o nome do seu projeto.
- Acesso para configurar segredos no repositório do GitHub.

---

## Etapa 1 — Criar o projeto Google Cloud

Diferente de uma implantação com dois projetos separados, aqui **um
único identificador de projeto** é usado tanto para teste quanto para
produção. Ele não precisa seguir nenhum padrão de sufixo — a aplicação
sabe distinguir teste de produção de outra forma (uma configuração
explícita injetada na implantação, não o nome do projeto).

```bash
gcloud projects create {PROJETO} --name="Observability Hub"

gcloud billing projects link {PROJETO} --billing-account={ID_DA_CONTA_DE_FATURAMENTO}
```

O ID da conta de faturamento pode ser consultado com
`gcloud billing accounts list`.

---

## Etapa 2 — Habilitar o banco de dados da aplicação

A aplicação guarda preferências de usuário e o controle de acesso
interno em bancos Firestore — um por ambiente, ambos dentro do mesmo
projeto. Esta etapa habilita a API; os dois bancos em si são criados
automaticamente na Etapa 6, junto com o resto da infraestrutura:

```bash
gcloud services enable firestore.googleapis.com --project={PROJETO}
```

---

## Etapa 3 — Ajustar a configuração para o seu projeto

O repositório de código faz referência ao nome do projeto original em
alguns arquivos de configuração. Antes de aplicar qualquer coisa,
substitua esse nome pelo escolhido na Etapa 1 nos seguintes arquivos
(o mesmo nome de projeto se repete em todos, já que é um projeto só):

| Arquivo | O que ajustar |
|---|---|
| `infra/terraform/bootstrap/variables.tf` | Nome do projeto e repositório GitHub |
| `infra/terraform/environments/dev/variables.tf` | Nome do projeto |
| `infra/terraform/environments/prod/variables.tf` | Nome do projeto (o mesmo valor) |
| `infra/terraform/environments/dev/versions.tf` | Nome do bucket de estado do Terraform |
| `infra/terraform/environments/prod/versions.tf` | Nome do bucket de estado do Terraform (o mesmo valor) |
| Os 4 arquivos de pipeline em `.github/workflows/` (`backend-deploy-*`, `frontend-deploy-*`) | Nome do projeto (o mesmo valor nos 4) |

---

## Etapa 4 — Preparar a base de implantação (uma única vez)

Esta etapa cria a fundação necessária: o local de armazenamento seguro
do estado da infraestrutura, a confiança entre GitHub e Google Cloud, e
as duas identidades usadas nas implantações automáticas (uma para
teste, uma para produção). Diferente de uma implantação com dois
projetos, essa preparação roda **uma única vez** — não uma vez por
ambiente:

```bash
cd infra/terraform/bootstrap
terraform init
terraform plan
terraform apply
```

`terraform plan` mostra exatamente o que será criado antes de qualquer
mudança real — revise antes de confirmar com `terraform apply`.

Ao final, capture os resultados (serão usados na próxima etapa):

```bash
terraform output state_bucket_name
terraform output -json workload_identity_providers
terraform output -json service_account_emails
```

Os dois últimos resultados trazem as duas identidades (teste e
produção) num único mapa cada.

---

## Etapa 5 — Conectar o GitHub ao Google Cloud

No repositório GitHub, em Configurações → Secrets and variables →
Actions, cadastre quatro segredos com os valores obtidos na etapa
anterior — cada um com o valor da entrada correspondente ('dev' ou
'prod') do mapa:

```bash
gh secret set WIF_PROVIDER_DEV --body "<entrada 'dev' de workload_identity_providers>"
gh secret set WIF_PROVIDER_PROD --body "<entrada 'prod' de workload_identity_providers>"
gh secret set WIF_SA_DEV --body "<entrada 'dev' de service_account_emails>"
gh secret set WIF_SA_PROD --body "<entrada 'prod' de service_account_emails>"
```

Isso é o que permite que o pipeline de implantação autentique no Google
Cloud sem nenhuma chave fixa, como descrito na seção de segurança acima.

### Aprovação obrigatória antes de qualquer atualização em produção

O ambiente de produção **não** publica uma atualização sozinho — mesmo
depois de o código estar pronto, alguém precisa aprovar manualmente
antes de ela realmente subir. Configure isso agora, também em
Configurações → Environments:

1. **New environment**, nome exatamente `production`
2. Marque **"Required reviewers"** e adicione quem deve aprovar
   atualizações de produção
3. Salve

Sem este passo, o ambiente de produção volta a publicar automaticamente
a cada alteração — a aprovação manual só existe se este environment
estiver configurado.

---

## Etapa 6 — Primeira implantação da infraestrutura

Com os arquivos da Etapa 3 já salvos no repositório, publique-os em uma
branch de trabalho (não a branch principal) — isso cria automaticamente
as duas aplicações (backend e frontend) do ambiente de **teste**, o
banco Firestore de teste, e um repositório compartilhado de imagens que
os dois ambientes vão usar, tudo dentro do único projeto criado na
Etapa 1.

Confirme que a execução foi concluída com sucesso antes de prosseguir.

Para o ambiente de produção, essa mesma criação (aplicações + banco
Firestore de produção) só acontece quando as alterações forem
publicadas na branch principal — deixe para depois de validar tudo em
teste (Etapa 13).

---

## Etapa 7 — Conceder as permissões internas da aplicação

A aplicação backend precisa de duas permissões para funcionar — acesso
ao banco de dados e ao cofre de credenciais (próxima etapa). Como teste
e produção têm identidades próprias mesmo estando no mesmo projeto,
conceda para **cada uma das duas**:

```bash
for AMBIENTE in dev prod; do
  CONTA_DE_SERVICO="backend-${AMBIENTE}-run@{PROJETO}.iam.gserviceaccount.com"

  gcloud projects add-iam-policy-binding {PROJETO} \
    --member="serviceAccount:${CONTA_DE_SERVICO}" --role="roles/datastore.user" --condition=None

  gcloud projects add-iam-policy-binding {PROJETO} \
    --member="serviceAccount:${CONTA_DE_SERVICO}" --role="roles/secretmanager.secretAccessor" --condition=None
done
```

Essas permissões existem só dentro do próprio projeto — não concedem
acesso a nada externo. Elas são concedidas a nível de projeto (o Google
Cloud não tem um conceito de "permissão por banco Firestore" separado);
o isolamento entre os dados de teste e produção é garantido pela própria
aplicação, que nunca lê o banco do ambiente errado.

---

## Etapa 8 — Configurar o login (Google OAuth)

A aplicação usa "Entrar com Google" para autenticação, solicitando
apenas identificação básica (nome, e-mail, foto de perfil) — nenhuma
permissão sensível.

1. No **Google Cloud Console → APIs & Services → OAuth consent screen**,
   configure a tela de consentimento (uso interno da organização, ou
   externo publicado em modo de produção, conforme sua preferência).
2. Em **APIs & Services → Credentials**, crie uma credencial do tipo
   "OAuth client ID" → "Web application" — uma para cada ambiente
   (teste e produção usam credenciais separadas, mesmo estando no
   mesmo projeto).
3. Em **Authorized redirect URIs**, cadastre o endereço da aplicação
   frontend de cada ambiente seguido de `/auth/callback`. Os endereços
   podem ser consultados com:
   ```bash
   gcloud run services describe frontend-dev --project={PROJETO} --region={REGIAO} \
     --format='value(status.url)'
   gcloud run services describe frontend-prod --project={PROJETO} --region={REGIAO} \
     --format='value(status.url)'
   ```
4. Anote o **Client ID** e o **Client Secret** de cada credencial — vão
   para o cofre de credenciais na próxima etapa.

---

## Etapa 9 — Guardar as credenciais de login

Todas as credenciais vivem no mesmo projeto — o que separa teste de
produção é o nome de cada entrada, não o projeto onde estão guardadas:

```bash
# ambiente de teste
echo -n "{CLIENT_ID_TESTE}"     | gcloud secrets create GOOGLE_OAUTH_CLIENT_ID_DEV --data-file=- --project={PROJETO}
echo -n "{CLIENT_SECRET_TESTE}" | gcloud secrets create GOOGLE_OAUTH_CLIENT_SECRET_DEV --data-file=- --project={PROJETO}
echo -n "{CHAVE_ALEATORIA_TESTE}" | gcloud secrets create JWT_SECRET_DEV --data-file=- --project={PROJETO}

# ambiente de produção
echo -n "{CLIENT_ID_PRODUCAO}"     | gcloud secrets create GOOGLE_OAUTH_CLIENT_ID_PROD --data-file=- --project={PROJETO}
echo -n "{CLIENT_SECRET_PRODUCAO}" | gcloud secrets create GOOGLE_OAUTH_CLIENT_SECRET_PROD --data-file=- --project={PROJETO}
echo -n "{CHAVE_ALEATORIA_PRODUCAO}" | gcloud secrets create JWT_SECRET_PROD --data-file=- --project={PROJETO}

# compartilhado entre os dois ambientes de propósito — só controla quem
# pode entrar na aplicação, não isolamento entre teste e produção
echo -n '{"allowed_domains": ["seudominio.com"], "allowed_emails": []}' \
  | gcloud secrets create OAUTH_ALLOWLIST --data-file=- --project={PROJETO}
```

`{CHAVE_ALEATORIA_TESTE}`/`{CHAVE_ALEATORIA_PRODUCAO}` podem ser geradas
com `openssl rand -hex 32` — **use valores realmente diferentes um do
outro**. Isso é mais importante aqui do que seria com dois projetos
separados: se os dois valores forem iguais por engano, uma sessão de
login criada no ambiente de teste passaria a ser aceita também no de
produção. `allowed_domains`/`allowed_emails` definem quem pode entrar na
aplicação — ajuste para a realidade da sua equipe.

---

## Etapa 10 — Confirmar a implantação da aplicação

O pipeline de implantação constrói e publica as duas aplicações de
teste automaticamente a cada alteração de código. Confirme que as
execuções mais recentes foram concluídas com sucesso antes de seguir
para a validação.

---

## Etapa 11 — Criar o primeiro administrador

Sem este passo, ninguém consegue acessar a área administrativa da
aplicação. Execute localmente, com suas próprias credenciais:

```bash
gcloud auth application-default login   # caso ainda não tenha feito

cd apps/backend
uv run python ../../scripts/seed_admin.py \
  --project {PROJETO} --environment dev --email {seu-email-administrador}
```

O parâmetro `--environment` é obrigatório: mesmo estando no mesmo
projeto, teste e produção usam bancos de dados separados, e este
comando precisa saber em qual dos dois criar o administrador.

---

## Etapa 12 — Validar o ambiente de teste

1. Acesse o endereço da aplicação frontend de teste.
2. Clique em "Entrar com Google" e autentique com um e-mail autorizado
   na Etapa 9.
3. Se for o mesmo e-mail cadastrado como administrador (Etapa 11),
   confirme que a área administrativa está acessível.

Com isso, o ambiente de teste está validado e pronto para uso.

---

## Etapa 13 — Repetir para produção

1. Publique as alterações da Etapa 3 na branch principal do
   repositório — isso cria a infraestrutura de produção automaticamente
   (as duas aplicações e o banco Firestore de produção, dentro do
   mesmo projeto).
2. **A publicação das duas aplicações fica parada esperando aprovação**
   (se a Etapa 5 foi configurada) — acesse a aba de execuções do
   repositório, localize a execução parada e aprove-a manualmente para
   que a atualização siga adiante.
3. Repita a Etapa 8 (credencial de login de produção — já separada da
   de teste desde a Etapa 9) e a Etapa 11 apontando
   `--environment prod`. A Etapa 7 (permissões) e a Etapa 9 (segredos)
   já cobriram os dois ambientes de uma vez, se você seguiu o loop
   acima — não precisam ser repetidas.
4. Repita a validação da Etapa 12 no ambiente de produção.

---

## Verificação final

```
[ ] Projeto único escolhido (não precisa terminar em "-dev"/"-prod"
    nesta versão da aplicação — ver Etapa 1)
[ ] Projeto Google Cloud criado, com faturamento vinculado
[ ] API do banco de dados habilitada (Etapa 2)
[ ] Arquivos de configuração ajustados e publicados no repositório
    (mesmo nome de projeto em todos)
[ ] Base de implantação preparada — uma única vez (Etapa 4)
[ ] Segredos do GitHub configurados (os quatro com valores diferentes
    entre teste e produção)
[ ] Aprovação obrigatória de produção configurada (Etapa 5)
[ ] Primeira implantação de teste confirmada com sucesso — cria as
    aplicações de teste, o banco de teste e o repositório de imagens
    compartilhado
[ ] Permissões internas concedidas às duas identidades (teste e
    produção)
[ ] Login configurado (teste e produção, credenciais separadas)
[ ] Credenciais de login guardadas no cofre — inclusive as duas chaves
    de sessão (teste e produção) com valores DIFERENTES entre si
[ ] Primeiro administrador de teste criado
[ ] Ambiente de teste validado — login e área administrativa funcionando
[ ] Atualização de produção aprovada manualmente (Etapa 13) — cria as
    aplicações de produção e o banco de produção
[ ] Primeiro administrador de produção criado
[ ] Ambiente de produção validado — login e área administrativa funcionando
```

---

## Em caso de dúvida

Alguns pontos merecem atenção especial ao longo do processo:

- **A ordem das etapas importa.** Cada uma depende do resultado da
  anterior — vale a pena confirmar que uma etapa foi concluída com
  sucesso antes de iniciar a próxima.
- **Os comandos são seguros para repetir.** A maioria das operações
  deste manual pode ser executada novamente sem causar duplicidade ou
  efeito colateral, caso seja necessário refazer algum passo.
- **Nada aqui afeta sistemas fora do projeto criado.** Se algo não sair
  como esperado, o ambiente pode ser recriado do zero sem risco para
  qualquer outro recurso da sua organização.
- **Teste e produção compartilham o mesmo projeto, não os mesmos
  dados.** Cada aplicação (Cloud Run), cada banco de dados (Firestore) e
  cada credencial de sessão (chave de assinatura de login) tem sua
  própria entrada nomeada por ambiente — é essa nomenclatura, não uma
  fronteira de projeto, que mantém teste e produção separados.

Para qualquer dúvida durante a execução, entre em contato com nossa
equipe em **{e-mail ou canal de suporte}**.

---

## Próximos passos

Com a aplicação no ar, o próximo passo é liberar o acesso de leitura
aos projetos Google Cloud que você deseja observar — um processo
separado e igualmente simples, coberto em um manual complementar
fornecido à parte.
