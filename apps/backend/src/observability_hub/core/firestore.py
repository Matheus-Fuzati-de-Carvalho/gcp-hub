"""Client compartilhado do Firestore — mesmo padrão de
core/bigquery.py::get_client() (client cacheado por processo via
lru_cache, sem estado por request). Usado pelos domínios favorites e
history.
"""

from functools import lru_cache

from google.cloud import firestore

from observability_hub.core.config import settings


@lru_cache
def get_firestore_client() -> firestore.Client:
    # Firestore named database (não o "(default)" implícito): dev e prod
    # rodam no mesmo projeto GCP (topologia single-project), então usar o
    # banco default misturaria os dados dos dois ambientes na mesma coleção
    # (login_events, favorites, hub_users, etc.). O banco "hub-dev"/
    # "hub-prod" precisa existir previamente (google_firestore_database no
    # Terraform de cada ambiente). Prefixo "hub-" porque database_id do
    # Firestore exige no mínimo 4 caracteres — "dev" sozinho (3) é
    # rejeitado pela API.
    return firestore.Client(database=f"hub-{settings.environment}")
