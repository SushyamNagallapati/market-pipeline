-- 7-day rolling average of the close price, per ticker.

{{ config(materialized='view') }}

SELECT
    symbol,
    company,
    price_date,
    close_price,

    -- window: the current row plus the 6 before it, separately for each ticker
    ROUND(
        AVG(close_price) OVER (
            PARTITION BY symbol
            ORDER BY price_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ), 4
    ) AS rolling_avg_7d,

    -- how far the close sits above (+) or below (-) the 7-day average
    ROUND(
        close_price - AVG(close_price) OVER (
            PARTITION BY symbol
            ORDER BY price_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ), 4
    ) AS deviation_from_avg

FROM {{ ref('daily_summary') }}
ORDER BY symbol, price_date