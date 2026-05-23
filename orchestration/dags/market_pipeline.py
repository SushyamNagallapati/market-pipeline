"""
market_pipeline.py
------------------
Main Airflow DAG for the market data pipeline.
Runs daily at 6am ET (after market data is available).

Task order:
fetch_prices ─┐
              ├─→ dbt_run
fetch_news   ─┘

fetch_prices and fetch_news run in parallel.
dbt_run waits for both to complete before transforming.
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator

# Default args apply to every task in the DAG
# Retries mean a flaky API won't fail the whole pipeline
default_args = {
    "owner": "pipeline",
    "depends_on_past": False,       # don't wait for yesterday's run
    "retries": 2,                   # retry twice before marking failed
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": False,      # set to True with SMTP config in production
}

with DAG(
    dag_id="market_pipeline",
    default_args=default_args,
    description="Daily market data ingestion and transformation",
    schedule="0 11 * * 1-5",       # 6am ET = 11am UTC, weekdays only
    start_date=datetime(2026, 1, 1),
    catchup=False,                  # don't backfill missed runs on startup
    tags=["market", "ingestion", "dbt"],
) as dag:

    # Task 1 — fetch stock prices
    fetch_prices = PythonOperator(
        task_id="fetch_prices",
        python_callable=lambda: __import__(
            "ingestion.fetch_prices", fromlist=["main"]
        ).main(),
    )

    # Task 2 — fetch news (runs in parallel with fetch_prices)
    fetch_news = PythonOperator(
        task_id="fetch_news",
        python_callable=lambda: __import__(
            "ingestion.fetch_news", fromlist=["main"]
        ).main(),
    )

    # Task 3 — run dbt models (waits for both ingestion tasks)
    # Task 3 — run dbt models (waits for both ingestion tasks)
    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command="/home/airflow/.local/bin/dbt run --profiles-dir /opt/airflow/dbt_project --project-dir /opt/airflow/dbt_project",
    )

    # Define dependencies — this is the DAG structure
    # [fetch_prices, fetch_news] >> dbt_run means:
    # both must succeed before dbt_run starts
    [fetch_prices, fetch_news] >> dbt_run