"""Streamlit dashboard over the dbt views in the analytics schema.

Run locally with `streamlit run dashboard/app.py`.
"""

import os
import streamlit as st
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
from sqlalchemy import create_engine
from dotenv import load_dotenv

load_dotenv()

st.set_page_config(
    page_title="Market Pipeline Dashboard",
    page_icon="📈",
    layout="wide"
)

@st.cache_resource
def get_engine():
    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", 5432)
    db = os.getenv("POSTGRES_DB")
    user = os.getenv("POSTGRES_USER")
    password = os.getenv("POSTGRES_PASSWORD")
    return create_engine(
        f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{db}"
    )

@st.cache_data(ttl=300)
def load_prices():
    engine = get_engine()
    return pd.read_sql("""
        SELECT symbol, company, sector, price_date,
               open_price, close_price, pct_change,
               is_significant_move
        FROM analytics.daily_summary
        ORDER BY symbol, price_date
    """, engine)

@st.cache_data(ttl=300)
def load_sentiment():
    engine = get_engine()
    return pd.read_sql("""
        SELECT symbol, news_date, article_count,
               avg_sentiment, sentiment_label, top_headline,
               close_price, pct_change
        FROM analytics.news_sentiment
        ORDER BY symbol, news_date
    """, engine)

@st.cache_data(ttl=300)
def load_rolling():
    engine = get_engine()
    return pd.read_sql("""
        SELECT symbol, price_date, close_price,
               rolling_avg_7d, deviation_from_avg
        FROM analytics.rolling_avg
        ORDER BY symbol, price_date
    """, engine)

st.title("Market Pipeline Dashboard")
st.caption("Refreshed daily at 6am ET by Airflow. Source: Yahoo Finance and NewsAPI, transformed with dbt.")

prices_df   = load_prices()
sentiment_df = load_sentiment()
rolling_df  = load_rolling()

if prices_df.empty:
    st.warning("No data found. Run the pipeline first.")
    st.stop()

# sidebar
st.sidebar.header("Filters")
all_symbols = sorted(prices_df["symbol"].unique().tolist())
selected = st.sidebar.multiselect(
    "Select tickers",
    all_symbols,
    default=all_symbols
)

if not selected:
    st.warning("Select at least one ticker.")
    st.stop()

prices_f   = prices_df[prices_df["symbol"].isin(selected)]
sentiment_f = sentiment_df[sentiment_df["symbol"].isin(selected)]
rolling_f  = rolling_df[rolling_df["symbol"].isin(selected)]

# latest prices
st.subheader("Latest close prices")
cols = st.columns(len(selected))

for i, symbol in enumerate(selected):
    row = prices_f[prices_f["symbol"] == symbol].iloc[-1]
    cols[i].metric(
        label=symbol,
        value=f"${row['close_price']:.2f}",
        delta=f"{row['pct_change']:.2f}%"
    )

st.divider()

# price history
st.subheader("Close price history")
fig_price = px.line(
    prices_f,
    x="price_date",
    y="close_price",
    color="symbol",
    markers=True,
    labels={"price_date": "Date", "close_price": "Close price ($)"}
)
fig_price.update_layout(
    legend_title="Ticker",
    hovermode="x unified",
    height=350
)
st.plotly_chart(fig_price, use_container_width=True)

st.divider()

# rolling average and sentiment, side by side
col_left, col_right = st.columns(2)

with col_left:
    st.subheader("7-day rolling average")
    if not rolling_f.empty:
        fig_roll = go.Figure()
        for symbol in selected:
            sym_df = rolling_f[rolling_f["symbol"] == symbol]
            fig_roll.add_trace(go.Scatter(
                x=sym_df["price_date"],
                y=sym_df["close_price"],
                name=f"{symbol} close",
                mode="markers",
                marker=dict(size=6)
            ))
            fig_roll.add_trace(go.Scatter(
                x=sym_df["price_date"],
                y=sym_df["rolling_avg_7d"],
                name=f"{symbol} 7d avg",
                mode="lines",
                line=dict(dash="dash")
            ))
        fig_roll.update_layout(height=350, hovermode="x unified")
        st.plotly_chart(fig_roll, use_container_width=True)
    else:
        st.info("Not enough data for rolling average yet.")

with col_right:
    st.subheader("News sentiment")
    if not sentiment_f.empty:
        fig_sent = px.bar(
            sentiment_f,
            x="symbol",
            y="avg_sentiment",
            color="sentiment_label",
            color_discrete_map={
                "positive": "#2ecc71",
                "neutral":  "#95a5a6",
                "negative": "#e74c3c"
            },
            labels={"avg_sentiment": "Avg sentiment score"},
            height=350
        )
        st.plotly_chart(fig_sent, use_container_width=True)
    else:
        st.info("No sentiment data available.")

st.divider()

# headlines
st.subheader("Top headlines by ticker")
if not sentiment_f.empty:
    headlines = sentiment_f[["symbol", "news_date", "sentiment_label",
                              "avg_sentiment", "top_headline"]].copy()
    headlines = headlines.sort_values("avg_sentiment", ascending=False)
    st.dataframe(
        headlines,
        use_container_width=True,
        hide_index=True,
        column_config={
            "avg_sentiment": st.column_config.NumberColumn(format="%.3f"),
            "sentiment_label": "Sentiment",
            "top_headline": st.column_config.TextColumn(width="large")
        }
    )