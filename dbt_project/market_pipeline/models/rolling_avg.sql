-- models/rolling_avg.sql

-- 7-day rolling average of close price per ticker.
-- Uses SQL window functions — runs across a partition of rows
-- without collapsing them like GROUP BY would.

-- Window functions are one of the most tested SQL concepts
-- in data engineering interviews.

{{ config(materialized='view') }}

SELECT
    symbol,
    company,
    price_date,
    close_price,

    -- AVG() OVER() = window function
    -- PARTITION BY = calculate separately for each ticker
    -- ORDER BY = defines the window frame direction
    -- ROWS BETWEEN 6 PRECEDING AND CURRENT ROW = last 7 days
    ROUND(
        AVG(close_price) OVER (
            PARTITION BY symbol
            ORDER BY price_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ), 4
    ) AS rolling_avg_7d,

    -- How far is today's price from the 7d average?
    -- Positive = trading above average (bullish signal)
    -- Negative = trading below average (bearish signal)
    ROUND(
        close_price - AVG(close_price) OVER (
            PARTITION BY symbol
            ORDER BY price_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ), 4
    ) AS deviation_from_avg

FROM {{ ref('daily_summary') }}
ORDER BY symbol, price_date