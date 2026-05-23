-- ============================================================
-- Market Pipeline — initial schema
-- File: db/schema/001_init.sql
-- Runs automatically on first Postgres container startup
-- ============================================================

-- DIMENSION TABLE: tickers
-- Stores context about each stock — changes rarely
-- One row per ticker, not one row per day
CREATE TABLE IF NOT EXISTS dim_tickers (
    ticker_id   SERIAL PRIMARY KEY,
    symbol      VARCHAR(10)  NOT NULL UNIQUE,  -- e.g. 'AAPL', 'TSLA'
    company     VARCHAR(255) NOT NULL,          -- e.g. 'Apple Inc'
    sector      VARCHAR(100),                   -- e.g. 'Technology'
    exchange    VARCHAR(50),                    -- e.g. 'NASDAQ'
    created_at  TIMESTAMP DEFAULT NOW()
);

-- FACT TABLE: daily prices
-- One row per ticker per day — this table grows every single day
-- References dim_tickers so we don't repeat company info
CREATE TABLE IF NOT EXISTS fact_prices (
    price_id        SERIAL PRIMARY KEY,
    ticker_id       INT NOT NULL REFERENCES dim_tickers(ticker_id),
    price_date      DATE NOT NULL,
    open_price      NUMERIC(12, 4),
    close_price     NUMERIC(12, 4),
    high_price      NUMERIC(12, 4),
    low_price       NUMERIC(12, 4),
    volume          BIGINT,
    ingested_at     TIMESTAMP DEFAULT NOW(),  -- when WE loaded it, not when market closed

    -- deduplication: can't have two rows for same ticker on same day
    CONSTRAINT uq_price_per_day UNIQUE (ticker_id, price_date)
);

-- FACT TABLE: news articles
-- One row per article — independent from prices but joinable by date
CREATE TABLE IF NOT EXISTS fact_news (
    news_id         SERIAL PRIMARY KEY,
    headline        TEXT NOT NULL,
    source          VARCHAR(100),              -- e.g. 'Reuters', 'Bloomberg'
    url             TEXT,
    published_at    TIMESTAMP,
    related_ticker  VARCHAR(10),              -- loose reference, not a FK
                                              -- news often covers multiple tickers
    sentiment_score NUMERIC(4, 3),            -- will be populated by dbt later (-1 to 1)
    ingested_at     TIMESTAMP DEFAULT NOW(),

    -- deduplication: same headline from same source = duplicate
    CONSTRAINT uq_article UNIQUE (headline, source)
);

-- INDEXES: speed up the queries our dashboard will run most often
-- Without indexes, Postgres scans every row — slow at scale
CREATE INDEX IF NOT EXISTS idx_prices_date
    ON fact_prices(price_date DESC);          -- "show me last 30 days" queries

CREATE INDEX IF NOT EXISTS idx_prices_ticker
    ON fact_prices(ticker_id);               -- "show me all AAPL rows" queries

CREATE INDEX IF NOT EXISTS idx_news_published
    ON fact_news(published_at DESC);         -- "show me today's news" queries