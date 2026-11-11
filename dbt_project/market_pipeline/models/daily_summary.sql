-- Daily summary per ticker: prices plus the day's change.
-- A view for now; switch to a table if the dashboard gets slow.

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

    ROUND((p.close_price - p.open_price), 4)                    AS price_change,
    ROUND((p.close_price - p.open_price) / p.open_price * 100, 2) AS pct_change,

    -- anything over 3% either way counts as a big move
    CASE
        WHEN ABS((p.close_price - p.open_price) / p.open_price * 100) > 3
        THEN true
        ELSE false
    END AS is_significant_move

FROM {{ ref('stg_prices') }} p
JOIN {{ source('public', 'dim_tickers') }} t
    ON p.ticker_id = t.ticker_id