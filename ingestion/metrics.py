"""Tiny run-stats recorder: appends each pipeline run to a JSON file for Grafana.

A real setup would push these to Prometheus instead.
"""

import json
import os
import time
from datetime import datetime, date
from pathlib import Path

METRICS_FILE = os.getenv("METRICS_FILE", "/tmp/pipeline_metrics.json")


def load_metrics() -> dict:
    """Read the metrics file, or start fresh if it's missing or broken."""
    try:
        with open(METRICS_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"runs": []}


def save_metrics(metrics: dict) -> None:
    """Write the metrics file, creating the folder if needed."""
    Path(METRICS_FILE).parent.mkdir(parents=True, exist_ok=True)
    with open(METRICS_FILE, "w") as f:
        json.dump(metrics, f, indent=2, default=str)


class PipelineRun:
    """Times a task and records how it went.

        with PipelineRun("fetch_prices") as run:
            ...
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

        # only keep the most recent 100 runs
        metrics["runs"] = metrics["runs"][-100:]
        save_metrics(metrics)

        return False  # never swallow the exception
