"""
fetch_prices.py
---------------
Pulls daily OHLCV data from Yahoo Finance for a watchlist of tickers.
Inserts into fact_prices, referencing dim_tickers.

Run manually:  python ingestion/fetch_prices.py
Run via Airflow: triggered by market_pipeline DAG
"""

import os
import logging
from datetime import date, timedelta

import yfinance as yf
import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

# Load .env file — reads POSTGRES_* variables into os.environ
load_dotenv()

# ── Logging setup ──────────────────────────────────────────────────────────
# logging > print() because:
# - log levels (INFO, WARNING, ERROR) let you filter noise
# - Airflow captures logs automatically — print() gets lost
# - timestamps tell you exactly when each step ran
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)

# ── Config ─────────────────────────────────────────────────────────────────
# Watchlist — in production this would come from dim_tickers table
# We hardcode for now to keep this script focused
TICKERS = ["AAPL", "TSLA", "MSFT", "GOOGL", "AMZN"]

# Fetch yesterday's data — markets close at 4pm ET
# If you run at 7am, yesterday's close is the latest available
FETCH_DATE = date.today() - timedelta(days=1)


def get_db_connection():
    """
    Create and return a Postgres connection using .env credentials.
    Kept as a function so it's easy to swap for a connection pool later.
    """
    return psycopg2.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=os.getenv("POSTGRES_PORT", 5432),
        dbname=os.getenv("POSTGRES_DB"),
        user=os.getenv("POSTGRES_USER"),
        password=os.getenv("POSTGRES_PASSWORD")
    )


def ensure_ticker_exists(cursor, symbol: str) -> int:
    """
    Get ticker_id for a symbol, inserting into dim_tickers if not present.
    This is called 'upsert' pattern — insert or get existing.

    Why not just use ticker_id=1 hardcoded?
    Because fact_prices has a foreign key to dim_tickers.
    You can't insert a price row without a valid ticker_id.
    """
    # Try to fetch existing ticker
    cursor.execute(
        "SELECT ticker_id FROM dim_tickers WHERE symbol = %s",
        (symbol,)
    )
    row = cursor.fetchone()

    if row:
        return row[0]  # already exists, return its id

    # Fetch company info from yfinance
    ticker_info = yf.Ticker(symbol).info
    company = ticker_info.get("longName", symbol)   # fallback to symbol if name missing
    sector = ticker_info.get("sector", "Unknown")
    exchange = ticker_info.get("exchange", "Unknown")

    cursor.execute(
        """
        INSERT INTO dim_tickers (symbol, company, sector, exchange)
        VALUES (%s, %s, %s, %s)
        RETURNING ticker_id
        """,
        (symbol, company, sector, exchange)
    )
    new_id = cursor.fetchone()[0]
    log.info(f"Inserted new ticker: {symbol} ({company})")
    return new_id


def fetch_and_insert_prices(ticker: str, conn) -> None:
    """
    Fetch one day of OHLCV data for a ticker and insert into fact_prices.
    Skips gracefully if data already exists (idempotent).
    """
    log.info(f"Fetching {ticker} for {FETCH_DATE}")

    try:
        # yfinance expects start/end as strings, end is exclusive
        df = yf.download(
            ticker,
            start=str(FETCH_DATE),
            end=str(FETCH_DATE + timedelta(days=1)),
            progress=False    # suppress yfinance's own progress bar
        )

        if df.empty:
            # This happens on weekends, holidays, or API issues
            log.warning(f"No data returned for {ticker} on {FETCH_DATE} — market closed or API issue")
            return

        # df has one row — grab it
        row = df.iloc[0]

        with conn.cursor() as cursor:
            ticker_id = ensure_ticker_exists(cursor, ticker)

           # NEW — explicit .iloc[0] fixes the warning
            open_p  = float(row["Open"].iloc[0])
            close_p = float(row["Close"].iloc[0])
            high_p  = float(row["High"].iloc[0])
            low_p   = float(row["Low"].iloc[0])
            volume  = int(row["Volume"].iloc[0])
            
            cursor.execute(
                """
                INSERT INTO fact_prices
                    (ticker_id, price_date, open_price, close_price,
                    high_price, low_price, volume)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT ON CONSTRAINT uq_price_per_day DO NOTHING
                """,
                (ticker_id, FETCH_DATE, open_p, close_p, high_p, low_p, volume)
            )
            conn.commit()
            log.info(f"Inserted {ticker} close={close_p:.2f}")

    except Exception as e:
        # Roll back this ticker's transaction but continue with next ticker
        # One bad ticker shouldn't kill the whole pipeline run
        conn.rollback()
        log.error(f"Failed to process {ticker}: {e}")


def main():
    log.info(f"Starting price ingestion for {FETCH_DATE}")
    log.info(f"Watchlist: {TICKERS}")

    try:
        conn = get_db_connection()
        log.info("Connected to Postgres")
    except Exception as e:
        # If we can't connect to DB, fail immediately — nothing else can work
        log.error(f"Database connection failed: {e}")
        raise  # re-raise so Airflow marks this task as failed

    for ticker in TICKERS:
        fetch_and_insert_prices(ticker, conn)

    conn.close()
    log.info("Price ingestion complete")


if __name__ == "__main__":
    main()