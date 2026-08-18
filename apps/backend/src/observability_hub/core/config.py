from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

# Regiões conhecidas do BigQuery consultadas em paralelo para descobrir
# automaticamente onde um projeto tem datasets (ver docs/specs/catalog.md).
BQ_REGIONS = [
    "US",
    "EU",
    "us-central1",
    "us-east1",
    "us-east4",
    "us-west1",
    "us-west2",
    "us-west3",
    "us-west4",
    "northamerica-northeast1",
    "southamerica-east1",
    "europe-west1",
    "europe-west2",
    "europe-west3",
    "europe-west4",
    "europe-west6",
    "europe-north1",
    "asia-east1",
    "asia-east2",
    "asia-northeast1",
    "asia-northeast2",
    "asia-northeast3",
    "asia-south1",
    "asia-southeast1",
    "asia-southeast2",
    "australia-southeast1",
]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="OBSERVABILITY_HUB_")

    # Topologia single-project: dev e prod rodam no mesmo projeto GCP, então
    # o project_id não serve mais pra distinguir ambiente (ver core/secrets.py
    # ::_is_prod). Sem default — falha rápido no startup se não for injetada
    # pelo Terraform (module cloud-run, env = { OBSERVABILITY_HUB_ENVIRONMENT
    # = "dev"/"prod" }) em vez de silenciosamente cair num ambiente errado.
    environment: Literal["dev", "prod"]
    # E-mail da própria service account de runtime do Cloud Run, injetado
    # pelo Terraform (google_service_account.runtime.email, ver módulo
    # cloud-run) — usado em main.py e domains/access/service.py em vez de
    # reconstruir o nome a partir de get_client().project + um literal
    # hardcoded, que quebra em projeto único (dev e prod têm SAs com nomes
    # diferentes no mesmo projeto: backend-dev-run vs backend-prod-run).
    runtime_sa_email: str

    log_level: str = "INFO"
    region_discovery_max_workers: int = 8
    # Preço on-demand do BigQuery por TiB processado (cloud.google.com/bigquery/pricing).
    # Usado só pra estimativa de custo em domains/quality — não afeta billing real.
    bigquery_price_usd_per_tib: float = 6.25
    # Preço de storage do BigQuery por GB/mês (cloud.google.com/bigquery/pricing,
    # região US). "Active" = tabela modificada nos últimos 90 dias; "long_term"
    # = sem modificação há 90+ dias, o BQ já rebaixa a tarifa sozinho — usado
    # em domains/finops pra estimar custo de storage de tabelas sem uso.
    bigquery_storage_price_usd_per_gb_month_active: float = 0.02
    bigquery_storage_price_usd_per_gb_month_long_term: float = 0.01
    # Preço de storage do Cloud Storage por GB/mês (cloud.google.com/storage/
    # pricing, região US, multi-region). Usado em domains/storage pra estimar
    # a faixa de economia do scanner de desperdício (STANDARD → NEARLINE/
    # COLDLINE) — não afeta billing real, mesma premissa dos preços do BQ
    # acima. ARCHIVE de propósito fora da faixa (retrieval caro + duração
    # mínima de 365 dias tornam a recomendação automática arriscada).
    gcs_storage_price_usd_per_gb_month_standard: float = 0.020
    gcs_storage_price_usd_per_gb_month_nearline: float = 0.010
    gcs_storage_price_usd_per_gb_month_coldline: float = 0.004
    # Origens liberadas pro CORS do frontend, separadas por vírgula (o
    # frontend roda em outra origem tanto em dev — Vite dev server — quanto
    # em prod — outro serviço Cloud Run).
    cors_origins: str = "http://localhost:5173"

    @property
    def cors_origins_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


settings = Settings()
