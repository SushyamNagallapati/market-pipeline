"""
metrics.py

Lightweight metrics collection for the market pipeline.
Writes pipeline run stats to a JSON file that Grafana can read.
In production this would push to Prometheus — same concept, simpler setup.
"""

import json
import os
import time
from datetime import datetime, date
from pathlib import Path

METRICS_FILE = os.getenv("METRICS_FILE", "/tmp/pipeline_metrics.json")


def load_metrics() -> dict:
    """Load existing metrics or return empty structure."""
    try:
        with open(METRICS_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"runs": []}


def save_metrics(metrics: dict) -> None:
    """Save metrics to file."""
    Path(METRICS_FILE).parent.mkdir(parents=True, exist_ok=True)
    with open(METRICS_FILE, "w") as f:
        json.dump(metrics, f, indent=2, default=str)


class PipelineRun:
    """
    Context manager that tracks a pipeline run.
    Records start time, end time, duration, rows inserted, and status.

    Usage:
        with PipelineRun("fetch_prices") as run:
            # do work
            run.rows_inserted = 5
    """

    def __init__(self, task_name: str):
        self.task_name = task_name
        self.start_time = None
        self.rows_inserted = 0
        self.status = "success"
        self.error = None

    def __enter__(self):
        self.start_time = time.time()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        duration = round(time.time() - self.start_time, 2)

        if exc_type is not None:
            self.status = "failed"
            self.error = str(exc_val)

        # Load existing metrics and append this run
        metrics = load_metrics()
        metrics["runs"].append({
            "task": self.task_name,
            "date": str(date.today()),
            "timestamp": datetime.utcnow().isoformat(),
            "duration_seconds": duration,
            "rows_inserted": self.rows_inserted,
            "status": self.status,
            "error": self.error
        })

        # Keep only last 30 days of runs
        metrics["runs"] = metrics["runs"][-100:]
        save_metrics(metrics)

        # Don't suppress exceptions
        return False