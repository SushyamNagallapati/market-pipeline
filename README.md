# Market Pipeline

A production-grade data pipeline that pulls daily stock prices and news headlines, transforms them with dbt, orchestrates with Airflow, and serves a live dashboard on Kubernetes.

Built to learn how data engineering, DevOps, and cloud infrastructure fit together in a real system.

---

## What it does

Every weekday at 6am ET, the pipeline:

1. Pulls closing prices for AAPL, TSLA, MSFT, GOOGL, AMZN from Yahoo Finance
2. Pulls relevant news headlines from NewsAPI
3. Loads raw data into Postgres with deduplication
4. Runs dbt models to calculate daily summaries, 7-day rolling averages, and sentiment scores
5. Serves a Streamlit dashboard that reads from the transformed views

The pipeline is idempotent. Running it twice on the same day produces the same result.

---

## Tech stack

| Layer            | Tools                                                    |
| ---------------- | -------------------------------------------------------- |
| Ingestion        | Python, yfinance, NewsAPI                                |
| Storage          | PostgreSQL 15 (star schema)                              |
| Transformation   | dbt                                                      |
| Orchestration    | Apache Airflow                                           |
| Dashboard        | Streamlit, Plotly                                        |
| Containerization | Docker, Docker Compose                                   |
| CI/CD            | GitHub Actions                                           |
| Infrastructure   | Terraform                                                |
| Cloud            | Azure Container Apps, Azure Database for PostgreSQL           |
| Observability    | Grafana                                                  |

---

## Architecture

Raw data lands in a star schema in Postgres. The `fact_prices` and `fact_news` tables store events. The `dim_tickers` table stores company metadata. dbt reads from the raw tables and writes transformed views into an `analytics` schema. Streamlit reads only from the analytics schema.

Airflow runs the full DAG daily. fetch_prices and fetch_news run in parallel, then dbt runs after both complete.

---

## Running locally

**Requirements:** Docker, Python 3.12, a free NewsAPI key from newsapi.org

**Clone and set up:**

```bash
git clone https://github.com/SushyamNagallapati/market-pipeline.git
cd market-pipeline
cp .env.example .env
# Fill in your values in .env
```

**Start Postgres and Airflow:**

```bash
docker compose up -d
```

**Install Python dependencies:**

```bash
pip install yfinance psycopg2-binary requests python-dotenv dbt-postgres streamlit plotly pandas sqlalchemy
```

**Run ingestion manually:**

```bash
python ingestion/fetch_prices.py
python ingestion/fetch_news.py
```

**Run dbt transformations:**

```bash
cd dbt_project/market_pipeline
dbt run
```

**Start the dashboard:**

```bash
streamlit run dashboard/app.py
```

Open http://localhost:8501

---

## CI/CD

Every push to main triggers a GitHub Actions workflow that:

- Lints Python with flake8
- Spins up a real Postgres instance
- Loads the schema
- Runs dbt models and data quality tests

The deploy job only runs if all tests pass.

---

## Infrastructure

All Azure resources are provisioned with Terraform. From zero to full cloud deployment:

```bash
cd terraform
terraform init
terraform apply
```

Resources created: Azure Database for PostgreSQL Flexible Server, Container Apps Environment, Container Apps for Airflow and Streamlit.

Terraform state is stored remotely in Azure Storage. One-time setup:

```bash
./scripts/bootstrap-tfstate.sh        # creates the storage, writes terraform/backend.hcl
cd terraform
terraform init -backend-config=backend.hcl
```

Networking: the database has no public access. Container Apps run inside a VNet and reach Postgres through a private endpoint, with a private DNS zone and an NSG that only allows port 5432 from the apps subnet (see `terraform/network.tf`).

### CI/CD for infrastructure

- **Pull request:** `terraform.yml` runs format and validate checks, then `terraform plan` and comments the result on the PR.
- **Merge to main:** the same workflow runs `terraform apply`, pausing for approval via the `production` environment.
- **App releases:** `pipeline.yml` builds images and rolls them out. Terraform ignores the image field so the two never fight.
- **Login:** GitHub to Azure uses OIDC (no stored passwords). One-time setup: `./scripts/setup-github-oidc.sh <state-storage-account>`.

### Monitoring

`terraform/monitoring.tf` sends container, Postgres and Key Vault audit logs to a Log Analytics workspace (capped at 1 GB/day). Email alerts fire on high DB CPU, high DB storage and Airflow restarts, and a monthly budget warns before costs get out of hand. Set `alert_email` in `terraform.tfvars` (and the `ALERT_EMAIL` variable in GitHub).

### Bicep, Azure DevOps and PowerShell versions

These are for comparison; Terraform and GitHub Actions stay the primary setup.

- `infra/bicep/network.bicep`: the VNet, NSG, private DNS and private endpoint again in Bicep (6 resources vs 9 in Terraform, since subnets are inline). Deploy with `az deployment group create -g market-pipeline-rg -f infra/bicep/network.bicep -p infra/bicep/network.bicepparam`.
- `azure-devops/terraform-pipeline.yml`: the same validate, plan and apply flow as the GitHub workflow, with an approval on the `production` environment. Setup steps are at the top of the file.
- `scripts/bootstrap-tfstate.ps1`: PowerShell version of the state bootstrap script.

To tear everything down:

```bash
terraform destroy
```

---

## Kubernetes manifests (experimental)

The manifests in `terraform/kubernetes/` are kept for learning but are not used by the current deployment. The AKS cluster was removed from Terraform to avoid cost. Container Apps run the workloads. Copy `secrets.example.yml` to `secrets.yml` and fill it in before applying them to any cluster.

---

## Key design decisions

**Why separate ingestion and transformation?** They fail independently. If the Yahoo Finance API goes down, the dbt models still work on yesterday's data. If a dbt model breaks, raw data keeps landing safely.

**Why dbt instead of plain SQL scripts?** dbt models are version controlled, testable, and auto-document themselves. Schema changes go through pull requests. A broken model fails loudly instead of silently corrupting data.

**Why Airflow instead of cron?** Cron fails silently. Airflow shows every run's history, retries failed tasks, and only runs dbt after both ingestion tasks succeed. The dependency graph is explicit.

**Why Kubernetes for Streamlit?** Two replicas mean the dashboard stays up if one pod crashes. Kubernetes detects the failure and starts a replacement without any manual intervention.

---

## What I learned

This project forced me to think about each layer from a team perspective. Code quality gates in CI/CD, idempotent pipelines, infrastructure as code, and observability are not optional extras. They are what separates a script that works on your laptop from a system a team can operate.

The hardest part was not the code. It was understanding why each tool exists and what problem it solves that simpler alternatives cannot.

---

## Author

Sushyam Nagallapati
Master of Engineering in Systems Design, University of Waterloo
[GitHub Profile](https://github.com/SushyamNagallapati)
