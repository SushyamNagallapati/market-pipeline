# Market Pipeline

A daily pipeline that pulls stock prices and news headlines, transforms them with dbt, schedules everything in Airflow and serves a Streamlit dashboard. It runs locally with Docker Compose and is set up to deploy to Azure Container Apps with Terraform.

The first version worked but had the usual problems of something built quickly: credentials in git, Terraform state on one laptop, a database reachable from the public internet, and a deploy job that changed Azure behind Terraform's back. This is the second pass, mostly about fixing those properly.

**Status:** the pipeline runs end to end locally. The Azure stack has been applied once to an Azure for Students subscription (all 28 resources, dashboard returning 200, Airflow healthy) and destroyed the same day to keep costs down.

---

## Pipeline

Every weekday morning:

1. Prices for AAPL, TSLA, MSFT, GOOGL and AMZN come from Yahoo Finance.
2. Headlines come from NewsAPI, with a rough keyword sentiment score.
3. Both load into Postgres. Inserts are idempotent, so a re-run doesn't create duplicates.
4. dbt builds daily summaries, 7-day rolling averages and per-day sentiment.
5. Streamlit reads the dbt views and nothing else.

Raw data sits in `fact_prices`, `fact_news` and `dim_tickers`. dbt writes views to an `analytics` schema. The Airflow DAG runs the two fetches in parallel and starts dbt once both succeed.

| Layer          | Tools                                       |
| -------------- | ------------------------------------------- |
| Ingestion      | Python, yfinance, NewsAPI                   |
| Storage        | PostgreSQL 15                               |
| Transformation | dbt                                         |
| Orchestration  | Apache Airflow                              |
| Dashboard      | Streamlit, Plotly                           |
| Local          | Docker Compose, Grafana                     |
| Cloud          | Azure Container Apps, Postgres Flexible Server |
| IaC            | Terraform, with a Bicep version of the network |
| CI/CD          | GitHub Actions, with an Azure DevOps version |

## Running locally

Needs Docker, Python 3.12 and a NewsAPI key.

```bash
git clone https://github.com/SushyamNagallapati/market-pipeline.git
cd market-pipeline
cp .env.example .env     # fill in your values
docker compose up -d     # Postgres, Airflow, Grafana
pip install yfinance psycopg2-binary requests python-dotenv dbt-postgres streamlit plotly pandas sqlalchemy
```

Run ingestion by hand:

```bash
python ingestion/fetch_prices.py
python ingestion/fetch_news.py
```

`profiles.yml` reads its connection settings from the environment, so load `.env` before running dbt:

```bash
set -a; source .env; set +a
cd dbt_project/market_pipeline
dbt run
```

Dashboard at http://localhost:8501:

```bash
streamlit run dashboard/app.py
```

---

## What changed in this pass

| Problem in v1                                         | Now                                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------- |
| DB password and API key committed in `profiles.yml` and `secrets.yml` | dbt reads env vars; `secrets.yml` is untracked with an example template; real values live in Key Vault, read by the apps through a managed identity |
| Postgres firewall allowed `0.0.0.0` (any Azure customer) | Public access off. Reachable only through a private endpoint, with private DNS and an NSG allowing 5432 from the apps subnet |
| Terraform state in a local file                       | Remote state in Azure Storage with versioning, bootstrapped by script |
| Deploy job ran `az containerapp update` outside Terraform | Infra goes through `terraform.yml` (plan on PR, apply on merge behind an approval); `pipeline.yml` only rolls out images |
| Stored Azure credentials in GitHub secrets            | OIDC federation, no long-lived credential                           |
| No monitoring                                         | Log Analytics, Postgres and Key Vault audit logs, alerts, budget    |
| Unused 2-node AKS cluster in Terraform                | Removed                                                             |

## Azure layout

All in `terraform/`:

- `main.tf`: resource group, Postgres Flexible Server, Container Apps environment and the Airflow and Streamlit apps
- `network.tf`: VNet, apps and data subnets, NSG on the data subnet, private DNS zone and link, Postgres private endpoint
- `keyvault.tf`: RBAC-mode vault, user-assigned identity for the apps (Secrets User), secrets written by Terraform
- `monitoring.tf`: Log Analytics (1 GB/day cap), diagnostic settings, email alerts on DB CPU, DB storage and Airflow restarts, monthly budget

The Container Apps ignore changes to `image`, since releases come from `pipeline.yml`. Otherwise every plan would try to roll the apps back to `:latest`.

### Bootstrapping

Terraform needs its state storage before it can create anything, so the first run goes in this order:

1. `az login`, then `./scripts/bootstrap-tfstate.sh` (or the `.ps1`). It creates the state storage and writes `terraform/backend.hcl`.
2. Create `terraform/terraform.tfvars` with the subscription ID, DB password, NewsAPI key, Docker Hub username and `alert_email`.
3. `cd terraform && terraform init -backend-config=backend.hcl && terraform plan`.
4. `terraform apply` from the same folder. The first run takes about 25 minutes, most of it the Container Apps environment.
5. For CI, run `./scripts/setup-github-oidc.sh <storage-account>` and add the variables and secrets it prints (needs a tenant that lets you create app registrations). Create a `production` environment with a required reviewer so applies wait for approval.

Your own user also needs `Storage Blob Data Contributor` on the state storage account, or `terraform init` fails with a 403. Owner on the subscription doesn't cover blob data.

Teardown is `terraform destroy`. The state storage isn't managed by Terraform, so remove it with `az group delete -n market-pipeline-tfstate-rg`.

## CI/CD

- `pipeline.yml`: flake8, then dbt run and test against a throwaway Postgres. On main it builds both images and points the Container Apps at them.
- `terraform.yml`: format check and validate on every run. Pull requests get the plan posted as a comment. Merging to main applies the saved plan after approval. Runs are serialized so two jobs never fight over the state lock. The plan and apply jobs are skipped until the `AZURE_CLIENT_ID` repo variable exists, so the checks stay green on a fork or a tenant without OIDC.

## Alternative implementations

Kept alongside for comparison, not wired into the main flow:

- `infra/bicep/network.bicep`: same network in Bicep. Six resources against nine in Terraform, because subnets and the NSG attachment are inline.
- `azure-devops/terraform-pipeline.yml`: the same validate, plan and apply flow for Azure DevOps, using a workload identity service connection.
- `scripts/bootstrap-tfstate.ps1`: PowerShell port of the bootstrap script.

`terraform/kubernetes/` holds manifests from an earlier AKS experiment. Nothing uses them.

---

## Design notes

**Separate ingestion and transformation.** They fail independently. If Yahoo Finance is down, dbt still runs on yesterday's data. If a model breaks, raw data keeps landing.

**Airflow over cron.** Run history, retries, and an explicit dependency so dbt only starts after both fetches succeed.

**Container Apps over AKS.** Two small services don't justify running a cluster. The AKS resource was the biggest line item and nothing was deployed to it.

**Private endpoint over an IP allow-list.** Removing the public path is easier to reason about than maintaining rules, and "allow Azure services" turned out to be far wider than the name suggests.

**Separate Terraform and app deploys.** Infra changes are rare and reviewed; image rollouts are frequent. Keeping them in separate workflows lets each have the right gate.

## Open items

- The first apply turned up one bug: the apps subnet needs a delegation to `Microsoft.App/environments`. Fixed. The apps-to-Postgres path through the private endpoint hasn't been tested with data loaded yet.
- CI apply is untested. The university tenant blocks app registrations, so OIDC couldn't be set up and the one apply was run from a laptop. `terraform.yml` should work on a tenant that allows it.
- Student subscriptions restrict regions. Mine allowed only centralus, eastus2, northcentralus, southcentralus and mexicocentral, so `location` and `db_location` are overridden in `terraform.tfvars`.
- Rotate the NewsAPI key and the old DB password. The originals are still in early commits.
- Airflow on Azure runs `airflow standalone` with its default SQLite metadata DB, so run history is lost whenever the container restarts. The proper fix is a second database on the Postgres server for Airflow's metadata.
- Key Vault allows public network access because Terraform runs on a GitHub-hosted runner and has to write the secrets. Callers still need an Azure AD token and a role. Going private-only means a self-hosted runner.
- The CI identity has Contributor and User Access Administrator at subscription scope. Fine for a sandbox, too broad otherwise. Scope it down once the resource groups exist.
- No NSG on the apps subnet yet. Container Apps need specific Azure-managed traffic allowed, and I want to test that before adding it.
- Sentiment is a keyword count. Replace with a proper model, probably as a dbt step.
- Add dbt tests beyond the basics and a data freshness check on the sources.

---

Sushyam Nagallapati
[GitHub](https://github.com/SushyamNagallapati)
