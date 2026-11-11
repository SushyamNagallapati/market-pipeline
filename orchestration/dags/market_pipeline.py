"""Daily market pipeline: fetch prices and news in parallel, then run dbt."""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator

# applied to every task in the DAG
default_args = {
    "owner": "pipeline",
    "depends_on_past": False,
    "retries": 2,                   # APIs flake out now and then
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": False,      # needs SMTP set up first
}

with DAG(
    dag_id="market_pipeline",
    default_args=default_args,
    description="Daily market data ingestion and transformation",
    schedule="0 11 * * 1-5",       # 6am ET = 11am UTC, weekdays only
    start_date=datetime(2026, 1, 1),
    catchup=False,                  # no backfilling
    tags=["market", "ingestion", "dbt"],
) as dag:

    # prices and news don't depend on each other, so they run in parallel
    fetch_prices = PythonOperator(
        task_id="fetch_prices",
        python_callable=lambda: __import__(
            "ingestion.fetch_prices", fromlist=["main"]
        ).main(),
    )

    fetch_news = PythonOperator(
        task_id="fetch_news",
        python_callable=lambda: __import__(
            "ingestion.fetch_news", fromlist=["main"]
        ).main(),
    )

    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command="/home/airflow/.local/bin/dbt run --profiles-dir /opt/airflow/dbt_project --project-dir /opt/airflow/dbt_project",
    )

    # dbt only runs once both ingestion tasks have succeeded
    [fetch_prices, fetch_news] >> dbt_run