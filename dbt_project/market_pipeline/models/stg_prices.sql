-- models/stg_prices.sql

-- Staging model — thin layer over raw fact_prices.
-- Staging models clean and standardize raw data before
-- downstream models use it. They never add business logic.

-- Why have a staging layer?
-- If Yahoo Finance changes their column names tomorrow,
-- you fix it in ONE staging model, not in every downstream model.

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