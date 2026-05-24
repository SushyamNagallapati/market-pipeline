"""
fetch_news.py
-------------
Pulls news headlines from NewsAPI for each ticker in our watchlist.
Inserts into fact_news with basic sentiment scoring.

Key differences from fetch_prices.py:
- Requires API key (rate limited — 100 requests/day on free tier)
- Handles text data instead of numbers
- No strict date constraint — articles can cover multiple tickers
"""

import os
import logging
import requests
from datetime import date, timedelta
from ingestion.metrics import PipelineRun

import psycopg2
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)

TICKERS = ["AAPL", "TSLA", "MSFT", "GOOGL", "AMZN"]

# Company names map — NewsAPI searches by keyword, not ticker symbol
# "AAPL" returns nothing, "Apple" returns articles
TICKER_KEYWORDS = {
    "AAPL": "Apple",
    "TSLA": "Tesla",
    "MSFT": "Microsoft",
    "GOOGL": "Google",
    "AMZN": "Amazon"
}

FETCH_DATE = date.today() - timedelta(days=1)
NEWS_API_KEY = os.getenv("NEWS_API_KEY")
NEWS_API_URL = "https://newsapi.org/v2/everything"


def get_db_connection():
    return psycopg2.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=os.getenv("POSTGRES_PORT", 5432),
        dbname=os.getenv("POSTGRES_DB"),
        user=os.getenv("POSTGRES_USER"),
        password=os.getenv("POSTGRES_PASSWORD")
    )


def simple_sentiment(headline: str) -> float:
    """
    Naive keyword-based sentiment score between -1.0 and 1.0.
    Returns 0.0 (neutral) if no keywords match.

    Why not use a real NLP model here?
    Because this script runs in the ingestion layer — fast and simple.
    The real sentiment analysis will be a dbt model later, or a separate
    ML step. Ingestion should just land data, not do heavy computation.
    This placeholder lets us populate the column now.
    """
    positive = ["surge", "gain", "record", "beat", "strong",
                "growth", "profit", "rise", "up", "high", "bull"]
    negative = ["fall", "drop", "miss", "weak", "loss", "down",
                "crash", "cut", "risk", "bear", "decline", "slump"]

    headline_lower = headline.lower()
    score = 0.0
    for word in positive:
        if word in headline_lower:
            score += 0.2
    for word in negative:
        if word in headline_lower:
            score -= 0.2

    # Clamp between -1.0 and 1.0
    return max(-1.0, min(1.0, score))


def fetch_news_for_ticker(ticker: str, conn) -> None:
    """
    Fetch yesterday's news for one ticker keyword and insert into fact_news.
    Skips duplicates via ON CONFLICT DO NOTHING — same as price ingestion.
    """
    keyword = TICKER_KEYWORDS.get(ticker, ticker)
    log.info(f"Fetching news for {ticker} (keyword: '{keyword}')")

    # Build request — NewsAPI free tier only allows searching last 30 days
    params = {
        "q": keyword,
        "from": str(FETCH_DATE),
        "to": str(FETCH_DATE),
        "language": "en",
        "sortBy": "publishedAt",
        "pageSize": 10,       # max 10 articles per ticker to stay within rate limits
        "apiKey": NEWS_API_KEY
    }

    try:
        response = requests.get(NEWS_API_URL, params=params, timeout=10)

        # Always check status before reading response body
        # A 429 means rate limited — back off, don't retry immediately
        if response.status_code == 429:
            log.warning(f"Rate limited by NewsAPI for {ticker} — skipping")
            return

        response.raise_for_status()  # raises for 4xx/5xx errors
        data = response.json()

        articles = data.get("articles", [])
        if not articles:
            log.warning(f"No articles found for {ticker} on {FETCH_DATE}")
            return

        inserted = 0
        skipped = 0

        with conn.cursor() as cursor:
            for article in articles:
                headline = article.get("title", "").strip()
                source = article.get("source", {}).get("name", "Unknown")
                url = article.get("url", "")
                published_at = article.get("publishedAt", "")
                sentiment = simple_sentiment(headline)

                if not headline or headline == "[Removed]":
                    # NewsAPI returns "[Removed]" for deleted articles
                    skipped += 1
                    continue

                cursor.execute(
                    """
                    INSERT INTO fact_news
                        (headline, source, url, published_at,
                         related_ticker, sentiment_score)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT ON CONSTRAINT uq_article DO NOTHING
                    """,
                    (headline, source, url, published_at,
                     ticker, sentiment)
                )
                if cursor.rowcount > 0:
                    inserted += 1
                else:
                    skipped += 1

            conn.commit()

        log.info(f"{ticker}: {inserted} inserted, {skipped} skipped")

    except requests.exceptions.Timeout:
        log.error(f"NewsAPI request timed out for {ticker}")
    except requests.exceptions.RequestException as e:
        log.error(f"NewsAPI request failed for {ticker}: {e}")
        conn.rollback()


def main():
    if not NEWS_API_KEY:
        raise ValueError("NEWS_API_KEY not set in .env file")

    log.info(f"Starting news ingestion for {FETCH_DATE}")

    with PipelineRun("fetch_news") as run:
        try:
            conn = get_db_connection()
            log.info("Connected to Postgres")
        except Exception as e:
            log.error(f"Database connection failed: {e}")
            raise

        total_inserted = 0
        for ticker in TICKERS:
            fetch_news_for_ticker(ticker, conn)
            total_inserted += 1

        conn.close()
        run.rows_inserted = total_inserted
        log.info("News ingestion complete")


if __name__ == "__main__":
    main()
