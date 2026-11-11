-- News sentiment per ticker per day, next to that day's price move.

{{ config(materialized='view') }}

WITH daily_sentiment AS (
    SELECT
        related_ticker                          AS symbol,
        DATE(published_at)                      AS news_date,
        COUNT(*)                                AS article_count,
        ROUND(AVG(sentiment_score), 3)          AS avg_sentiment,
        ROUND(MAX(sentiment_score), 3)          AS max_sentiment,
        ROUND(MIN(sentiment_score), 3)          AS min_sentiment,

        -- the day's most positive headline
        (ARRAY_AGG(headline ORDER BY sentiment_score DESC))[1]
                                                AS top_headline

    FROM {{ source('public', 'fact_news') }}
    WHERE related_ticker IS NOT NULL
      AND published_at IS NOT NULL
    GROUP BY related_ticker, DATE(published_at)
)

SELECT
    ds.symbol,
    ds.news_date,
    ds.article_count,
    ds.avg_sentiment,
    ds.max_sentiment,
    ds.min_sentiment,
    ds.top_headline,

    -- label for the dashboard
    CASE
        WHEN ds.avg_sentiment >  0.2 THEN 'positive'
        WHEN ds.avg_sentiment < -0.2 THEN 'negative'
        ELSE 'neutral'
    END AS sentiment_label,

    p.close_price,
    p.pct_change

FROM daily_sentiment ds
LEFT JOIN {{ ref('daily_summary') }} p
    ON ds.symbol = p.symbol
    AND ds.news_date = p.price_date
ORDER BY ds.symbol, ds.news_date