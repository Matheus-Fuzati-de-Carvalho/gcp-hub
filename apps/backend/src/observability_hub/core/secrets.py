"""Leitura de secrets do Secret Manager em runtime — nunca via variável de
ambiente estática (CLAUDE.md, Guardrails). Usado hoje só pelo domínio auth
(credenciais OAuth, JWT_SECRET, allowlist), mas mora em core/ porque não é
específico de um domínio.
"""

import json
from functools import lru_cache

from google.cloud import secretmanager

from observability_hub.core.bigquery import get_runtime_project
from observability_hub.core.config import settings

# GOOGLE_OAUTH_CLIENT_ID/SECRET e JWT_SECRET têm um secret por ambiente
# (_DEV/_PROD) — dev e prod estão no mesmo projeto (topologia
# single-project deste repositório), então sem o sufixo seria literalmente
# o mesmo secret do Secret Manager pros dois ambientes. Pra OAuth isso já
# seria quebrado por natureza (client IDs distintos, URLs de callback
# diferentes); pra JWT_SECRET seria uma falha de isolamento sutil e grave —
# um token de sessão assinado por dev seria válido em prod e vice-versa.
# OAUTH_ALLOWLIST é o único que continua com nome (e valor) compartilhado
# de propósito: controla só quem pode logar, não isolamento de sessão.


@lru_cache
def _is_prod() -> bool:
    # Ambiente é sempre explícito (settings.environment, injetado via
    # OBSERVABILITY_HUB_ENVIRONMENT pelo Terraform) — nunca inferido do
    # project_id, que é idêntico pros dois ambientes neste repositório.
    return settings.environment == "prod"


@lru_cache
def get_secret(secret_id: str) -> str:
    """access_secret_version na versão "latest" — cacheado por processo
    (mesmo racional do get_table_cached de core/bigquery.py: secrets não
    mudam com frequência, e cada leitura é uma chamada de API)."""
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{get_runtime_project()}/secrets/{secret_id}/versions/latest"
    response = client.access_secret_version(name=name)
    return response.payload.data.decode("utf-8")


def get_oauth_client_id() -> str:
    return get_secret("GOOGLE_OAUTH_CLIENT_ID_PROD" if _is_prod() else "GOOGLE_OAUTH_CLIENT_ID_DEV")


def get_oauth_client_secret() -> str:
    secret_id = (
        "GOOGLE_OAUTH_CLIENT_SECRET_PROD" if _is_prod() else "GOOGLE_OAUTH_CLIENT_SECRET_DEV"
    )
    return get_secret(secret_id)


def get_jwt_secret() -> str:
    return get_secret("JWT_SECRET_PROD" if _is_prod() else "JWT_SECRET_DEV")


def get_oauth_allowlist() -> dict:
    """{"allowed_domains": [...], "allowed_emails": [...]}"""
    return json.loads(get_secret("OAUTH_ALLOWLIST"))
