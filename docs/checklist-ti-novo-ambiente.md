# Checklist para o time de TI — provisionar o ambiente do Observability Hub

**Para quem é este documento:** o time de TI/infra que administra a
conta Google Cloud e o GitHub da empresa. Não é preciso entender o
funcionamento interno do Hub — é só uma lista do que precisa existir e
de quem precisa de qual acesso antes de alguém conseguir seguir o
playbook técnico de hospedagem (`docs/playbooks/hospedar-hub-em-novo-projeto.md`).

**Resumo em uma frase:** um projeto Google Cloud novo, com billing
vinculado, e uma pessoa com permissão de administrar esse projeto —
mais um repositório GitHub onde essa mesma pessoa tenha acesso de
administrador.

---

## 1. Google Cloud

### 1.1 Projeto

- [ ] Criar (ou autorizar a criação de) **um único projeto Google
      Cloud** para o Hub. Ele hospeda dois ambientes (teste e produção)
      dentro do mesmo projeto — não são necessários dois projetos.
- [ ] Escolher e informar o **ID do projeto** (ex: `acme-hub`) — vira
      referência em vários arquivos de configuração do repositório.

### 1.2 Billing

- [ ] Vincular uma conta de faturamento a esse projeto.
- [ ] **Confirmar que a conta de faturamento tem quota disponível para
      mais um projeto vinculado.** Contas de billing têm um limite de
      quantos projetos podem estar vinculados simultaneamente — se a
      conta já estiver no limite, `gcloud billing projects link` falha
      com `Cloud billing quota exceeded` (aconteceu de verdade no
      piloto deste playbook). Ou já verificar de antemão, ou saber que
      pode ser preciso desvincular um projeto não usado ou pedir
      aumento de quota.

### 1.3 Permissões da pessoa que vai executar o playbook

- [ ] Conceder papel de **Owner** no projeto novo à pessoa responsável
      pela hospedagem (ou, se preferir mais granular: Project IAM
      Admin + Service Usage Admin + Storage Admin + Workload Identity
      Pool Admin + Service Account Admin — o playbook técnico assume
      Owner por simplicidade).

### 1.4 Coisas que costumam estar restritas por política organizacional — vale confirmar antes

Nenhuma dessas restrições apareceu no piloto (projeto sem organização
por trás), mas empresas com Google Workspace/Cloud Identity
frequentemente têm políticas organizacionais (Org Policies) que podem
bloquear partes do playbook silenciosamente. Vale uma conversa
preventiva com quem administra a organização no Google Cloud:

- [ ] **Workload Identity Federation não pode estar bloqueada.** O
      deploy usa WIF pra autenticar o GitHub Actions sem chave de
      service account — se a organização tiver uma Org Policy
      restringindo criação de Workload Identity Pools, o bootstrap
      falha.
- [ ] **Domain Restricted Sharing não pode impedir conceder papéis a
      identidades federadas do GitHub.** Se a organização usa a
      constraint `iam.allowedPolicyMemberDomains` de forma restritiva,
      conceder `roles/iam.workloadIdentityUser` às identidades do
      GitHub Actions pode ser bloqueado.
- [ ] **Cloud Run precisa poder aceitar invocações não autenticadas**
      (`allUsers` com `roles/run.invoker`) nos dois serviços (backend e
      frontend) — o controle de acesso real é feito pela própria
      aplicação (login Google + allowlist), não pelo IAM do Cloud Run.
      Uma Org Policy `constraints/run.allowedIngress` ou
      `iam.allowedPolicyMemberDomains` restritiva pode bloquear isso.
- [ ] **Firestore Native mode precisa estar disponível** no projeto
      (é a API `firestore.googleapis.com`, sem restrição específica
      conhecida, mas vale confirmar se a organização usa alguma
      politica de "APIs permitidas").

Se qualquer uma dessas restrições existir, quem for rodar o playbook
técnico vai precisar de uma exceção específica pra este projeto —
melhor descobrir isso antes de começar do que no meio do bootstrap.

---

## 2. Google Workspace (tela de login OAuth)

- [ ] Decidir, com quem administra o Google Workspace da empresa: a
      tela de consentimento OAuth do Hub vai ser **Interna** (só
      contas do Workspace conseguem ver a tela — mais simples, exige
      que todo mundo que vai usar o Hub tenha conta no Workspace) ou
      **Externa** (qualquer conta Google, publicada como "Em
      produção" — não exige revisão do Google porque o Hub só pede
      escopos básicos: `openid`, `email`, `profile`, nenhum sensível).
- [ ] Se for **Interna**: confirmar que a pessoa que vai configurar o
      OAuth Client (playbook, passo 11) tem permissão de fazer isso no
      Workspace — em alguns casos é uma permissão separada da de Owner
      do projeto Google Cloud.
- [ ] O Hub não pede nenhum escopo de acesso a dados do Workspace
      (Drive, Gmail, Calendar, etc.) — só identificação básica de
      login. Não precisa de aprovação de segurança adicional por
      causa disso.

---

## 3. GitHub

- [ ] Criar (ou autorizar a criação de) um **repositório novo**, sob o
      controle da pessoa/equipe que vai hospedar o Hub — pode ser uma
      cópia direta deste repositório.
- [ ] Garantir que essa pessoa tem acesso de **administrador** nesse
      repositório — precisa configurar:
  - Secrets em Settings → Secrets and variables → Actions (credenciais
    de autenticação com o Google Cloud, sem nenhuma chave de longa
    duração — usa Workload Identity Federation)
  - Um GitHub Environment chamado `production` com "required
    reviewers" (gate de aprovação manual antes de qualquer atualização
    ir pro ambiente de produção)

Não é necessário nenhum plano pago do GitHub além do que a
organização já usa — Actions no plano gratuito já cobre o volume de
uso esperado (poucos deploys por dia).

---

## Depois de tudo isso pronto

A pessoa responsável segue
[`docs/playbooks/hospedar-hub-em-novo-projeto.md`](playbooks/hospedar-hub-em-novo-projeto.md)
do início ao fim — é autocontido a partir daqui, não precisa mais de
nada do time de TI além do que já foi concedido acima (a menos que
algum dos pontos da seção 1.4 realmente esteja restrito, aí vira uma
conversa pontual sobre aquela exceção específica).

Depois que o Hub estiver no ar, liberar acesso de leitura a outros
projetos Google Cloud (pra o Hub analisar os dados deles) é um processo
**separado**, coberto em
[`manual-liberacao-acesso-cliente.md`](manual-liberacao-acesso-cliente.md)
— cada dono de projeto roda aquele checklist pro próprio projeto,
depois que o Hub já estiver hospedado.
