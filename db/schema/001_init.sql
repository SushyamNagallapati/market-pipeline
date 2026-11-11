-- Initial schema. Postgres runs this on the container's first startup.

-- tickers: one row per stock, rarely changes
CREATE TABLE IF NOT EXISTS dim_tickers (
    ticker_id   SERIAL PRIMARY KEY,
    symbol      VARCHAR(10)  NOT NULL UNIQUE,  -- e.g. 'AAPL', 'TSLA'
    company     VARCHAR(255) NOT NULL,          -- e.g. 'Apple Inc'
    sector      VARCHAR(100),                   -- e.g. 'Technology'
    exchange    VARCHAR(50),                    -- e.g. 'NASDAQ'
    created_at  TIMESTAMP DEFAULT NOW()
);

-- prices: one row per ticker per day
CREATE TABLE IF NOT EXISTS fact_prices (
    price_id        SERIAL PRIMARY KEY,
    ticker_id       INT NOT NULL REFERENCES dim_tickers(ticker_id),
    price_date      DATE NOT NULL,
    open_price      NUMERIC(12, 4),
    close_price     NUMERIC(12, 4),
    high_price      NUMERIC(12, 4),
    low_price       NUMERIC(12, 4),
    volume          BIGINT,
    ingested_at     TIMESTAMP DEFAULT NOW(),  -- when we loaded it, not when the market closed

    -- one row per ticker per day
    CONSTRAINT uq_price_per_day UNIQUE (ticker_id, price_date)
);

-- news: one row per article, joined to prices by date later
CREATE TABLE IF NOT EXISTS fact_news (
    news_id         SERIAL PRIMARY KEY,
    headline        TEXT NOT NULL,
    source          VARCHAR(100),              -- e.g. 'Reuters', 'Bloomberg'
    url             TEXT,
    published_at    TIMESTAMP,
    related_ticker  VARCHAR(10),              -- not a FK, articles often cover several tickers
    sentiment_score NUMERIC(4, 3),            -- -1 to 1, keyword based for now
    ingested_at     TIMESTAMP DEFAULT NOW(),

    -- same headline from the same source counts as a duplicate
    CONSTRAINT uq_article UNIQUE (headline, source)
);

-- indexes for what the dashboard queries most
CREATE INDEX IF NOT EXISTS idx_prices_date
    ON fact_prices(price_date DESC);

CREATE INDEX IF NOT EXISTS idx_prices_ticker
    ON fact_prices(ticker_id);

CREATE INDEX IF NOT EXISTS idx_news_published
    ON fact_news(published_at DESC);