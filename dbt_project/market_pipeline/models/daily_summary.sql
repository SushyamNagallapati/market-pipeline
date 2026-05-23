-- models/daily_summary.sql
-- Aggregates raw price data into a clean daily summary per ticker.
-- Reads from public.fact_prices and public.dim_tickers.
-- dbt writes output to analytics.daily_summary automatically.

-- This is a VIEW by default — no data is stored, query runs on demand.
-- We'll make it a TABLE materialization in production for performance.

{{ config(materialized='view') }}

SELECT
    t.symbol,
    t.company,
    t.sector,
    p.price_date,
    p.open_price,
    p.close_price,
    p.high_price,
    p.low_price,
    p.volume,

    -- derived columns — calculated at query time
    ROUND((p.close_price - p.open_price), 4)                    AS price_change,
    ROUND((p.close_price - p.open_price) / p.open_price * 100, 2) AS pct_change,

    -- flag big moves — useful for dashboard alerts
    CASE
        WHEN ABS((p.close_price - p.open_price) / p.open_price * 100) > 3
        THEN true
        ELSE false
    END AS is_significant_move

FROM {{ ref('stg_prices') }} p
JOIN {{ source('public', 'dim_tickers') }} t
    ON p.ticker_id = t.ticker_id