"""Pull yesterday's prices from Yahoo Finance into fact_prices.

Run by hand with `python ingestion/fetch_prices.py`; Airflow runs it through
the market_pipeline DAG.
"""

import os
import logging
from datetime import date, timedelta

try:
    from ingestion.metrics import PipelineRun
except ModuleNotFoundError:
    from metrics import PipelineRun

import yfinance as yf
import psycopg2
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)

TICKERS = ["AAPL", "TSLA", "MSFT", "GOOGL", "AMZN"]
FETCH_DATE = date.today() - timedelta(days=1)


def get_db_connection():
    """Connect to Postgres using the POSTGRES_* environment variables."""
    return psycopg2.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=os.getenv("POSTGRES_PORT", 5432),
        dbname=os.getenv("POSTGRES_DB"),
        user=os.getenv("POSTGRES_USER"),
        password=os.getenv("POSTGRES_PASSWORD")
    )


def ensure_ticker_exists(cursor, symbol: str) -> int:
    """Return the ticker_id for a symbol, adding it to dim_tickers if it's new."""
    cursor.execute(
        "SELECT ticker_id FROM dim_tickers WHERE symbol = %s",
        (symbol,)
    )
    row = cursor.fetchone()

    if row:
        return row[0]

    ticker_info = yf.Ticker(symbol).info
    company = ticker_info.get("longName", symbol)
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


def fetch_and_insert_prices(ticker: str, conn) -> int:
    """Fetch one day of prices for a ticker and insert them. Safe to re-run.

    Returns how many rows were actually inserted (0 if it already existed).
    """
    log.info(f"Fetching {ticker} for {FETCH_DATE}")

    try:
        df = yf.download(
            ticker,
            start=str(FETCH_DATE),
            end=str(FETCH_DATE + timedelta(days=1)),
            progress=False
        )

        if df.empty:
            log.warning(
                f"No data returned for {ticker} on {FETCH_DATE} "
                f"(market closed, or the API is having a bad day)"
            )
            return 0

        row = df.iloc[0]

        with conn.cursor() as cursor:
            ticker_id = ensure_ticker_exists(cursor, ticker)

            # explicit .iloc[0] avoids FutureWarning from pandas
            open_p = float(row["Open"].iloc[0])
            close_p = float(row["Close"].iloc[0])
            high_p = float(row["High"].iloc[0])
            low_p = float(row["Low"].iloc[0])
            volume = int(row["Volume"].iloc[0])

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
            inserted = cursor.rowcount
            conn.commit()
            log.info(f"{ticker} close={close_p:.2f} ({inserted} new row)")
            return inserted

    except Exception as e:
        conn.rollback()
        log.error(f"Failed to process {ticker}: {e}")
        return 0


def main():
    log.info(f"Starting price ingestion for {FETCH_DATE}")
    log.info(f"Watchlist: {TICKERS}")

    with PipelineRun("fetch_prices") as run:
        try:
            conn = get_db_connection()
            log.info("Connected to Postgres")
        except Exception as e:
            log.error(f"Database connection failed: {e}")
            raise

        total_inserted = 0
        for ticker in TICKERS:
            total_inserted += fetch_and_insert_prices(ticker, conn)

        conn.close()
        run.rows_inserted = total_inserted
        log.info("Price ingestion complete")


if __name__ == "__main__":
    main()
