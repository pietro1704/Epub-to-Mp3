"""Build segment-level JSON, CSV and HTML reports from one metrics journal."""

from __future__ import annotations

import contextlib
import csv
import html
import json
import time
from collections import Counter
from pathlib import Path
from typing import Any, Dict, Optional


class SegmentMetricsReports:
    """Own segment aggregation and rendering without the converter lifecycle."""

    def __init__(self, path: Optional[Path], *, percentile=None, verbose=lambda: False):
        self.path = path
        self._percentile = percentile
        self._verbose = verbose

    def write_summary(self) -> None:
        metrics_path = self.path
        if metrics_path is None or not metrics_path.exists():
            return
        counts: Counter[str] = Counter()
        per_engine: Dict[str, Dict[str, Any]] = {}
        try:
            with metrics_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except Exception:
                        continue
                    event = str(payload.get("event") or "unknown")
                    counts[event] += 1
                    if event not in {
                        "segment_success",
                        "edge_request",
                        "edge_segment_validation",
                    }:
                        continue
                    engine = str(payload.get("engine") or "unknown").lower()
                    bucket = per_engine.setdefault(
                        engine,
                        {
                            "segments": 0.0,
                            "total_chars": 0.0,
                            "total_elapsed_s": 0.0,
                            "cps_values": [],
                            "elapsed_values": [],
                            "request_count": 0,
                            "successful_requests": 0,
                            "failed_requests": 0,
                            "request_ms_values": [],
                            "queue_wait_ms_values": [],
                            "write_ms_values": [],
                            "retry_values": [],
                            "error_categories": Counter(),
                            "validation_count": 0,
                            "failed_validations": 0,
                            "validation_ms_values": [],
                        },
                    )
                    if event == "edge_request":
                        status = str(payload.get("status") or "failed").strip().lower()
                        bucket["request_count"] += 1
                        if status == "success":
                            bucket["successful_requests"] += 1
                        else:
                            bucket["failed_requests"] += 1
                            category = str(payload.get("error_category") or "unknown").strip()
                            if category:
                                bucket["error_categories"][category] += 1
                        bucket["request_ms_values"].append(
                            max(0.0, float(payload.get("request_ms") or 0.0))
                        )
                        bucket["queue_wait_ms_values"].append(
                            max(0.0, float(payload.get("queue_wait_ms") or 0.0))
                        )
                        bucket["write_ms_values"].append(
                            max(0.0, float(payload.get("write_ms") or 0.0))
                        )
                        bucket["retry_values"].append(
                            max(0.0, float(payload.get("retry_count") or 0.0))
                        )
                        continue
                    if event == "edge_segment_validation":
                        bucket["validation_count"] += 1
                        if str(payload.get("status") or "failed").lower() != "success":
                            bucket["failed_validations"] += 1
                        bucket["validation_ms_values"].append(
                            max(0.0, float(payload.get("validation_ms") or 0.0))
                        )
                        continue
                    elapsed = float(payload.get("elapsed_s") or 0.0)
                    chars = float(payload.get("segment_chars") or 0.0)
                    cps = (chars / elapsed) if elapsed > 0 else 0.0
                    bucket["segments"] += 1.0
                    bucket["total_chars"] += chars
                    bucket["total_elapsed_s"] += elapsed
                    if cps > 0:
                        bucket["cps_values"].append(cps)
                    if elapsed > 0:
                        bucket["elapsed_values"].append(elapsed)

            engine_summary: Dict[str, Dict[str, Any]] = {}
            for engine, row in sorted(per_engine.items()):
                elapsed = max(0.001, float(row.get("total_elapsed_s") or 0.0))
                chars = float(row.get("total_chars") or 0.0)
                segs = max(1.0, float(row.get("segments") or 1.0))
                cps_values = [float(v) for v in (row.get("cps_values") or []) if float(v) > 0]
                elapsed_values = [
                    float(v) for v in (row.get("elapsed_values") or []) if float(v) > 0
                ]
                request_ms_values = [
                    max(0.0, float(v)) for v in (row.get("request_ms_values") or [])
                ]
                queue_wait_ms_values = [
                    max(0.0, float(v)) for v in (row.get("queue_wait_ms_values") or [])
                ]
                write_ms_values = [max(0.0, float(v)) for v in (row.get("write_ms_values") or [])]
                retry_values = [max(0.0, float(v)) for v in (row.get("retry_values") or [])]
                validation_ms_values = [
                    max(0.0, float(v)) for v in (row.get("validation_ms_values") or [])
                ]
                p50_cps = self._percentile(cps_values, 0.5)
                p95_cps = self._percentile(cps_values, 0.95)
                p50_elapsed = self._percentile(elapsed_values, 0.5)
                p95_elapsed = self._percentile(elapsed_values, 0.95)
                jitter_ratio = (p95_elapsed / max(0.001, p50_elapsed)) if p50_elapsed > 0 else 0.0
                engine_summary[engine] = {
                    "segments": int(segs),
                    "total_chars": int(chars),
                    "total_elapsed_s": round(elapsed, 3),
                    "avg_chars_per_second": round(chars / elapsed, 3),
                    "avg_chars_per_segment": round(chars / segs, 3),
                    "p50_chars_per_second": round(p50_cps, 3),
                    "p95_chars_per_second": round(p95_cps, 3),
                    "p50_elapsed_s": round(p50_elapsed, 3),
                    "p95_elapsed_s": round(p95_elapsed, 3),
                    "jitter_ratio": round(jitter_ratio, 3),
                    "request_count": int(row.get("request_count", 0) or 0),
                    "successful_requests": int(row.get("successful_requests", 0) or 0),
                    "failed_requests": int(row.get("failed_requests", 0) or 0),
                    "request_p50_ms": round(self._percentile(request_ms_values, 0.5), 3),
                    "request_p95_ms": round(self._percentile(request_ms_values, 0.95), 3),
                    "queue_wait_p50_ms": round(self._percentile(queue_wait_ms_values, 0.5), 3),
                    "queue_wait_p95_ms": round(self._percentile(queue_wait_ms_values, 0.95), 3),
                    "write_p50_ms": round(self._percentile(write_ms_values, 0.5), 3),
                    "write_p95_ms": round(self._percentile(write_ms_values, 0.95), 3),
                    "avg_retry_count": round(
                        sum(retry_values) / len(retry_values) if retry_values else 0.0, 3
                    ),
                    "retry_p95": round(self._percentile(retry_values, 0.95), 3),
                    "error_categories": dict(sorted(row["error_categories"].items())),
                    "validation_count": int(row.get("validation_count", 0) or 0),
                    "failed_validations": int(row.get("failed_validations", 0) or 0),
                    "validation_p50_ms": round(self._percentile(validation_ms_values, 0.5), 3),
                    "validation_p95_ms": round(self._percentile(validation_ms_values, 0.95), 3),
                }

            summary = {
                "generated_at": time.time(),
                "segment_metrics_file": str(metrics_path),
                "event_counts": dict(sorted(counts.items())),
                "engines": engine_summary,
            }
            summary_path = metrics_path.with_name("segment-metrics-summary.json")
            summary_path.write_text(
                json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
            )
        except Exception:
            if self._verbose():
                print("⚠️ Failed to write segment metrics summary")

    def write_csv(self) -> None:
        metrics_path = self.path
        if metrics_path is None or not metrics_path.exists():
            return
        rows: Dict[tuple[str, str], Dict[str, Any]] = {}
        try:
            with metrics_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except Exception:
                        continue
                    if str(payload.get("event") or "") != "segment_success":
                        continue
                    engine = str(payload.get("engine") or "").strip().lower()
                    chapter = str(payload.get("chapter") or "").strip()
                    if not engine or not chapter:
                        continue
                    key = (engine, chapter)
                    row = rows.setdefault(
                        key,
                        {
                            "engine": engine,
                            "chapter": chapter,
                            "segments": 0,
                            "total_chars": 0,
                            "total_elapsed_s": 0.0,
                            "avg_cps": 0.0,
                        },
                    )
                    row["segments"] += 1
                    row["total_chars"] += int(payload.get("segment_chars") or 0)
                    row["total_elapsed_s"] += float(payload.get("elapsed_s") or 0.0)
            csv_path = metrics_path.with_name("segment-metrics-engine-chapter.csv")
            fields = [
                "engine",
                "chapter",
                "segments",
                "total_chars",
                "total_elapsed_s",
                "avg_chars_per_second",
            ]
            with csv_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=fields)
                writer.writeheader()
                for key in sorted(rows.keys(), key=lambda item: (item[0], item[1])):
                    row = rows[key]
                    elapsed = max(0.001, float(row["total_elapsed_s"] or 0.0))
                    avg = float(row["total_chars"]) / elapsed
                    writer.writerow(
                        {
                            "engine": row["engine"],
                            "chapter": row["chapter"],
                            "segments": row["segments"],
                            "total_chars": row["total_chars"],
                            "total_elapsed_s": f"{elapsed:.3f}",
                            "avg_chars_per_second": f"{avg:.3f}",
                        }
                    )
        except Exception:
            if self._verbose():
                print("⚠️ Failed to write segment metrics CSV")

    def write_dashboard(self) -> None:
        metrics_path = self.path
        if metrics_path is None:
            return
        summary_path = metrics_path.with_name("segment-metrics-summary.json")
        csv_path = metrics_path.with_name("segment-metrics-engine-chapter.csv")
        if not summary_path.exists():
            return
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            engines = summary.get("engines", {}) if isinstance(summary, dict) else {}
            event_counts = summary.get("event_counts", {}) if isinstance(summary, dict) else {}
            total_segments = sum(
                int((entry or {}).get("segments", 0) or 0)
                for entry in (engines.values() if isinstance(engines, dict) else [])
                if isinstance(entry, dict)
            )
            cards = ""
            for engine, row in sorted((engines or {}).items()):
                if not isinstance(row, dict):
                    continue
                cards += (
                    "<div class='card'>"
                    f"<strong>{html.escape(str(engine))}</strong><br>"
                    f"Segments: {int(row.get('segments', 0) or 0)}<br>"
                    f"Avg chars/s: {float(row.get('avg_chars_per_second', 0.0) or 0.0):.1f}<br>"
                    f"P95 chars/s: {float(row.get('p95_chars_per_second', 0.0) or 0.0):.1f}<br>"
                    f"Jitter: {float(row.get('jitter_ratio', 0.0) or 0.0):.2f}x"
                    "</div>"
                )

            rows_html = ""
            if csv_path.exists():
                with csv_path.open("r", encoding="utf-8") as handle:
                    reader = csv.DictReader(handle)
                    for row in reader:
                        rows_html += (
                            "<tr>"
                            f"<td>{html.escape(str(row.get('engine', '')))}</td>"
                            f"<td>{html.escape(str(row.get('chapter', '')))}</td>"
                            f"<td>{html.escape(str(row.get('segments', '')))}</td>"
                            f"<td>{html.escape(str(row.get('total_chars', '')))}</td>"
                            f"<td>{html.escape(str(row.get('avg_chars_per_second', '')))}</td>"
                            "</tr>"
                        )
            chart_html = "<p>No segment cps timeline available.</p>"
            timeline_points: Dict[str, list[tuple[float, float]]] = {}
            if metrics_path.exists():
                with contextlib.suppress(Exception):
                    with metrics_path.open("r", encoding="utf-8") as handle:
                        for line in handle:
                            line = line.strip()
                            if not line:
                                continue
                            payload = json.loads(line)
                            if str(payload.get("event") or "") != "segment_success":
                                continue
                            engine = str(payload.get("engine") or "unknown").lower()
                            ts = float(payload.get("ts") or 0.0)
                            cps = float(payload.get("cps") or 0.0)
                            if ts <= 0.0 or cps <= 0.0:
                                continue
                            timeline_points.setdefault(engine, []).append((ts, cps))
            if timeline_points:
                all_ts = [pt[0] for points in timeline_points.values() for pt in points]
                all_cps = [pt[1] for points in timeline_points.values() for pt in points]
                min_ts = min(all_ts)
                max_ts = max(all_ts)
                max_cps = max(1.0, max(all_cps))
                width = 900.0
                height = 280.0
                pad_x = 42.0
                pad_y = 20.0
                plot_w = max(80.0, width - (pad_x * 2))
                plot_h = max(80.0, height - (pad_y * 2))
                palette = [
                    "#1f77b4",
                    "#d62728",
                    "#2ca02c",
                    "#9467bd",
                    "#ff7f0e",
                    "#17becf",
                ]
                lines: list[str] = [
                    f"<svg viewBox='0 0 {int(width)} {int(height)}' role='img' aria-label='chars per second over time'>",
                    f"<rect x='0' y='0' width='{int(width)}' height='{int(height)}' fill='#ffffff' stroke='#d0d7de' />",
                    f"<line x1='{pad_x}' y1='{height - pad_y}' x2='{width - pad_x}' y2='{height - pad_y}' stroke='#9aa4b2'/>",
                    f"<line x1='{pad_x}' y1='{pad_y}' x2='{pad_x}' y2='{height - pad_y}' stroke='#9aa4b2'/>",
                ]
                for idx, engine in enumerate(sorted(timeline_points.keys())):
                    points = sorted(timeline_points[engine], key=lambda item: item[0])
                    if len(points) < 2:
                        continue
                    color = palette[idx % len(palette)]
                    coords = []
                    for ts, cps in points:
                        if max_ts <= min_ts:
                            x = pad_x
                        else:
                            x = pad_x + ((ts - min_ts) / (max_ts - min_ts)) * plot_w
                        y = (height - pad_y) - ((cps / max_cps) * plot_h)
                        coords.append(f"{x:.1f},{y:.1f}")
                    lines.append(
                        f"<polyline fill='none' stroke='{color}' stroke-width='2' points='{' '.join(coords)}' />"
                    )
                    lines.append(
                        f"<text x='{pad_x + 6}' y='{pad_y + 14 + (idx * 14)}' fill='{color}' font-size='11'>{html.escape(engine)}</text>"
                    )
                lines.append(
                    f"<text x='{width - pad_x}' y='{pad_y + 12}' text-anchor='end' font-size='11' fill='#57606a'>max {max_cps:.1f} cps</text>"
                )
                lines.append("</svg>")
                chart_html = "".join(lines)
            dashboard = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Segment Metrics Dashboard</title>
  <style>
    body {{ font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 24px; color: #1b1f24; }}
    h1 {{ margin: 0 0 12px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-bottom: 18px; }}
    .card {{ border: 1px solid #d0d7de; border-radius: 8px; padding: 12px; background: #f6f8fa; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th, td {{ border: 1px solid #d0d7de; padding: 8px; text-align: left; vertical-align: top; }}
    th {{ background: #f3f4f6; }}
  </style>
</head>
<body>
  <h1>Segment Metrics Dashboard</h1>
  <div class="grid">
    <div class="card"><strong>Total segments</strong><br>{int(total_segments)}</div>
    <div class="card"><strong>Segment success events</strong><br>{int(event_counts.get('segment_success', 0) or 0)}</div>
    <div class="card"><strong>Pre-check events</strong><br>{int(event_counts.get('pre_segment_check', 0) or 0)}</div>
  </div>
  <div class="grid">{cards}</div>
  <h2>Chars/s Timeline</h2>
  {chart_html}
  <h2>Engine/Chapter Segments</h2>
  <table>
    <thead>
      <tr><th>Engine</th><th>Chapter</th><th>Segments</th><th>Total chars</th><th>Avg chars/s</th></tr>
    </thead>
    <tbody>{rows_html}</tbody>
  </table>
</body>
</html>
"""
            dashboard_path = metrics_path.with_name("segment-metrics-dashboard.html")
            dashboard_path.write_text(dashboard, encoding="utf-8")
        except Exception:
            if self._verbose():
                print("⚠️ Failed to write segment metrics dashboard")
