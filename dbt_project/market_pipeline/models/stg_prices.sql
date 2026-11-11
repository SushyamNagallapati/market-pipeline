-- Thin staging layer over fact_prices. If the source columns ever change,
-- this is the one place to fix. Rows with missing prices are dropped here.

{{ config(materialized='view') }}

SELECT
    price_id,
    ticker_id,
    price_date,
    open_price,
    close_price,
    high_price,
    low_price,
    volume,
    ingested_at
FROM {{ source('public', 'fact_prices') }}
WHERE open_price IS NOT NULL
  AND close_price IS NOT NULL