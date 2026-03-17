"""Metrics report writing mixin for AudioConverter."""

from __future__ import annotations

import contextlib
import csv
import html
import json
import time
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Optional


class _MetricsReportMixin:
    def _rotate_runtime_metrics_if_needed(self, path: Path, max_bytes: int = 2_000_000) -> None:
        try:
            if not path.exists():
                return
            if path.stat().st_size < max_bytes:
                return
            timestamp = time.strftime("%Y%m%d-%H%M%S")
            rotated = path.with_name(f"{path.stem}.{timestamp}{path.suffix}")
            path.replace(rotated)
            siblings = sorted(
                path.parent.glob(f"{path.stem}.*{path.suffix}"),
                key=lambda candidate: candidate.stat().st_mtime,
                reverse=True,
            )
            for stale in siblings[5:]:
                with contextlib.suppress(OSError):
                    stale.unlink(missing_ok=True)
        except Exception:
            if self.verbose:
                print("⚠️ Failed to rotate runtime metrics")

    def _write_runtime_metrics_summary(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._runtime_metrics_path(output_dir)
        if metrics_path is None or not metrics_path.exists():
            return
        event_counts: Counter[str] = Counter()
        engine_counts: Counter[str] = Counter()
        failure_counts: Counter[str] = Counter()
        edge_blocked_chapters: set[str] = set()
        chapters_total = 0
        chapters_ok = 0
        switches = 0
        total_events = 0
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
                    total_events += 1
                    event = str(payload.get("event") or "unknown")
                    event_counts[event] += 1
                    engine = str(payload.get("engine") or "").strip().lower()
                    if engine:
                        engine_counts[engine] += 1
                    if event == "chapter_complete":
                        chapters_total += 1
                        if bool(payload.get("success")):
                            chapters_ok += 1
                    if event == "engine_switch":
                        switches += 1
                    if event == "edge_blocked_chapter":
                        chapter_label = str(
                            payload.get("chapter_label") or payload.get("chapter") or ""
                        ).strip()
                        if chapter_label:
                            edge_blocked_chapters.add(chapter_label)
                    if "failed" in event or "failure" in event:
                        failure_counts[event] += 1

            summary = {
                "generated_at": time.time(),
                "metrics_file": str(metrics_path),
                "total_events": total_events,
                "chapters": {
                    "total": chapters_total,
                    "successful": chapters_ok,
                    "failed": max(0, chapters_total - chapters_ok),
                },
                "engine_events": dict(sorted(engine_counts.items())),
                "event_counts": dict(sorted(event_counts.items())),
                "failures": dict(sorted(failure_counts.items())),
                "engine_switches": switches,
                "edge_blocked_chapters": {
                    "count": len(edge_blocked_chapters),
                    "chapters": sorted(edge_blocked_chapters),
                },
                "optimization_metrics": {
                    "prefetch_requests": int(event_counts.get("prefetch_request", 0) or 0),
                    "prefetch_hits": int(event_counts.get("prefetch_hit", 0) or 0),
                    "prefetch_hit_rate": (
                        round(
                            float(event_counts.get("prefetch_hit", 0) or 0)
                            / float(event_counts.get("prefetch_request", 1) or 1),
                            4,
                        )
                        if int(event_counts.get("prefetch_request", 0) or 0) > 0
                        else 0.0
                    ),
                    "ab_explorations": int(event_counts.get("auto_ab_exploration", 0) or 0),
                    "budget_caps_applied": int(event_counts.get("resource_budget_cap", 0) or 0),
                    "adaptive_state_restores": int(
                        event_counts.get("adaptive_state_restored", 0) or 0
                    ),
                },
            }
            summary_path = metrics_path.with_name("metrics-summary.json")
            summary_path.write_text(
                json.dumps(summary, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write runtime metrics summary")

    def _write_runtime_metrics_csv(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._runtime_metrics_path(output_dir)
        if metrics_path is None or not metrics_path.exists():
            return
        chapter_engine_rows: Dict[tuple[str, str], Dict[str, Any]] = {}
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
                    if str(payload.get("event") or "") != "chapter_complete":
                        continue
                    chapter = str(payload.get("chapter") or "").strip()
                    engine = str(payload.get("engine") or "").strip().lower()
                    if not chapter or not engine:
                        continue
                    key = (chapter, engine)
                    row = chapter_engine_rows.setdefault(
                        key,
                        {
                            "chapter": chapter,
                            "engine": engine,
                            "attempts": 0,
                            "successes": 0,
                            "failures": 0,
                            "total_chars": 0,
                            "total_elapsed_s": 0.0,
                            "last_error": "",
                        },
                    )
                    row["attempts"] += 1
                    chars = int(payload.get("chars") or 0)
                    elapsed = float(payload.get("elapsed_s") or 0.0)
                    row["total_chars"] += max(0, chars)
                    row["total_elapsed_s"] += max(0.0, elapsed)
                    if bool(payload.get("success")):
                        row["successes"] += 1
                    else:
                        row["failures"] += 1
                        row["last_error"] = str(payload.get("error") or "")[:240]

            csv_path = metrics_path.with_name("metrics-chapter-engine.csv")
            fieldnames = [
                "chapter",
                "engine",
                "attempts",
                "successes",
                "failures",
                "total_chars",
                "total_elapsed_s",
                "avg_chars_per_second",
                "last_error",
            ]
            with csv_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=fieldnames)
                writer.writeheader()
                for key in sorted(
                    chapter_engine_rows.keys(),
                    key=lambda item: (str(item[0]), str(item[1])),
                ):
                    row = chapter_engine_rows[key]
                    elapsed_total = float(row["total_elapsed_s"] or 0.0)
                    avg_cps = (
                        float(row["total_chars"]) / elapsed_total if elapsed_total > 0 else 0.0
                    )
                    writer.writerow(
                        {
                            "chapter": row["chapter"],
                            "engine": row["engine"],
                            "attempts": row["attempts"],
                            "successes": row["successes"],
                            "failures": row["failures"],
                            "total_chars": row["total_chars"],
                            "total_elapsed_s": f"{elapsed_total:.3f}",
                            "avg_chars_per_second": f"{avg_cps:.3f}",
                            "last_error": row["last_error"],
                        }
                    )
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write runtime metrics CSV")

    def _write_runtime_metrics_dashboard(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._runtime_metrics_path(output_dir)
        if metrics_path is None:
            return
        summary_path = metrics_path.with_name("metrics-summary.json")
        csv_path = metrics_path.with_name("metrics-chapter-engine.csv")
        if not summary_path.exists():
            return
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            chapters = summary.get("chapters", {}) if isinstance(summary, dict) else {}
            total_events = (
                int(summary.get("total_events", 0) or 0) if isinstance(summary, dict) else 0
            )
            switches = (
                int(summary.get("engine_switches", 0) or 0) if isinstance(summary, dict) else 0
            )
            blocked_info = (
                summary.get("edge_blocked_chapters", {}) if isinstance(summary, dict) else {}
            )
            blocked_count = (
                int(blocked_info.get("count", 0) or 0) if isinstance(blocked_info, dict) else 0
            )
            blocked_list = (
                blocked_info.get("chapters", []) if isinstance(blocked_info, dict) else []
            )
            opt = summary.get("optimization_metrics", {}) if isinstance(summary, dict) else {}
            prefetch_hit_rate = float(opt.get("prefetch_hit_rate", 0.0) or 0.0)
            ab_explorations = int(opt.get("ab_explorations", 0) or 0)
            budget_caps = int(opt.get("budget_caps_applied", 0) or 0)
            adaptive_restores = int(opt.get("adaptive_state_restores", 0) or 0)
            rows_html = ""
            if csv_path.exists():
                with csv_path.open("r", encoding="utf-8") as handle:
                    reader = csv.DictReader(handle)
                    rows = list(reader)
                for row in rows:
                    rows_html += (
                        "<tr>"
                        f"<td>{html.escape(str(row.get('chapter', '')))}</td>"
                        f"<td>{html.escape(str(row.get('engine', '')))}</td>"
                        f"<td>{html.escape(str(row.get('attempts', '')))}</td>"
                        f"<td>{html.escape(str(row.get('successes', '')))}</td>"
                        f"<td>{html.escape(str(row.get('failures', '')))}</td>"
                        f"<td>{html.escape(str(row.get('avg_chars_per_second', '')))}</td>"
                        f"<td>{html.escape(str(row.get('last_error', '')))}</td>"
                        "</tr>"
                    )
            blocked_html = "".join(
                f"<li>{html.escape(str(chapter))}</li>" for chapter in (blocked_list or [])
            )
            dashboard = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Conversion Metrics Dashboard</title>
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
  <h1>Conversion Metrics Dashboard</h1>
  <div class="grid">
    <div class="card"><strong>Total events</strong><br>{total_events}</div>
    <div class="card"><strong>Chapters ok</strong><br>{int(chapters.get('successful', 0) or 0)}/{int(chapters.get('total', 0) or 0)}</div>
    <div class="card"><strong>Engine switches</strong><br>{switches}</div>
    <div class="card"><strong>Edge blocked chapters</strong><br>{blocked_count}</div>
    <div class="card"><strong>Prefetch hit rate</strong><br>{prefetch_hit_rate * 100:.1f}%</div>
    <div class="card"><strong>A/B explorations</strong><br>{ab_explorations}</div>
    <div class="card"><strong>Budget caps applied</strong><br>{budget_caps}</div>
    <div class="card"><strong>Adaptive restores</strong><br>{adaptive_restores}</div>
  </div>
  <h2>Chapter/Engine Attempts</h2>
  <table>
    <thead>
      <tr><th>Chapter</th><th>Engine</th><th>Attempts</th><th>Successes</th><th>Failures</th><th>Avg chars/s</th><th>Last error</th></tr>
    </thead>
    <tbody>{rows_html}</tbody>
  </table>
  <h2>Edge Blocked Chapters</h2>
  <ul>{blocked_html}</ul>
</body>
</html>
"""
            dashboard_path = metrics_path.with_name("metrics-dashboard.html")
            dashboard_path.write_text(dashboard, encoding="utf-8")
        except Exception:
            if self.verbose:
                print("⚠️ Failed to write metrics dashboard")

    def _write_segment_metrics_summary(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._segment_metrics_path(output_dir)
        if metrics_path is None or not metrics_path.exists():
            return
        counts: Counter[str] = Counter()
        per_engine: Dict[str, Dict[str, float]] = {}
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
                    if event != "segment_success":
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
                        },
                    )
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

            engine_summary: Dict[str, Dict[str, float]] = {}
            for engine, row in sorted(per_engine.items()):
                elapsed = max(0.001, float(row.get("total_elapsed_s") or 0.0))
                chars = float(row.get("total_chars") or 0.0)
                segs = max(1.0, float(row.get("segments") or 1.0))
                cps_values = [float(v) for v in (row.get("cps_values") or []) if float(v) > 0]
                elapsed_values = [
                    float(v) for v in (row.get("elapsed_values") or []) if float(v) > 0
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
            if self.verbose:
                print("⚠️ Failed to write segment metrics summary")

    def _write_segment_metrics_csv(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._segment_metrics_path(output_dir)
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
            if self.verbose:
                print("⚠️ Failed to write segment metrics CSV")

    def _write_segment_metrics_dashboard(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._segment_metrics_path(output_dir)
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
            timeline_points: Dict[str, List[tuple[float, float]]] = {}
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
                lines: List[str] = [
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
            if self.verbose:
                print("⚠️ Failed to write segment metrics dashboard")

    def _write_runtime_recommendations(self, output_dir: Optional[Path] = None) -> None:
        metrics_path = self._runtime_metrics_path(output_dir)
        if metrics_path is None:
            return
        summary_path = metrics_path.with_name("metrics-summary.json")
        segment_summary_path = metrics_path.with_name("segment-metrics-summary.json")
        if not summary_path.exists():
            return
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except Exception:
            return
        segment_summary: Dict[str, Any] = {}
        if segment_summary_path.exists():
            with contextlib.suppress(Exception):
                loaded = json.loads(segment_summary_path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    segment_summary = loaded

        recommendations: List[str] = []
        chapters = summary.get("chapters", {}) if isinstance(summary, dict) else {}
        total = int(chapters.get("total", 0) or 0)
        failed = int(chapters.get("failed", 0) or 0)
        switches = int(summary.get("engine_switches", 0) or 0) if isinstance(summary, dict) else 0
        opt = summary.get("optimization_metrics", {}) if isinstance(summary, dict) else {}
        hit_rate = float(opt.get("prefetch_hit_rate", 0.0) or 0.0)
        budget_caps = int(opt.get("budget_caps_applied", 0) or 0)
        blocked = summary.get("edge_blocked_chapters", {}) if isinstance(summary, dict) else {}
        blocked_count = int(blocked.get("count", 0) or 0) if isinstance(blocked, dict) else 0

        if total > 0 and (failed / max(1, total)) > 0.1:
            recommendations.append(
                "- High failure rate: enable `--engine auto` and keep automatic retries."
            )
        if blocked_count > 0:
            recommendations.append(
                "- Edge blocked chapters: reduce `EDGE_MAX_CONCURRENCY` or use offline fallback."
            )
        if hit_rate < 0.4:
            recommendations.append(
                "- Low prefetch hit rate: try `--stage-pipeline` and `--stage-pipeline-depth 3`."
            )
        if budget_caps > 3:
            recommendations.append(
                "- Resource budget reduced parallelism multiple times: lower `--parallel-slots`."
            )
        if switches > max(3, total // 2):
            recommendations.append(
                "- Many engine switches: pin the main engine for this book and compare with A/B."
            )

        if segment_summary:
            engines = segment_summary.get("engines", {})
            if isinstance(engines, dict) and engines:
                ranked = sorted(
                    (
                        (
                            str(name),
                            float((row or {}).get("avg_chars_per_second", 0.0) or 0.0),
                        )
                        for name, row in engines.items()
                        if isinstance(row, dict)
                    ),
                    key=lambda item: item[1],
                    reverse=True,
                )
                if ranked:
                    best_name, best_cps = ranked[0]
                    recommendations.append(
                        f"- Melhor engine nesta execução: `{best_name}` (~{best_cps:.1f} chars/s)."
                    )
                high_jitter = [
                    (name, float((row or {}).get("jitter_ratio", 0.0) or 0.0))
                    for name, row in engines.items()
                    if isinstance(row, dict)
                    and float((row or {}).get("jitter_ratio", 0.0) or 0.0) >= 2.5
                ]
                if high_jitter:
                    worst = sorted(high_jitter, key=lambda item: item[1], reverse=True)[0]
                    recommendations.append(
                        f"- Alta variabilidade de segmento em `{worst[0]}` ({worst[1]:.2f}x): "
                        "reduza chunk/concurrency para estabilidade."
                    )
                low_p50 = [
                    (name, float((row or {}).get("p50_chars_per_second", 0.0) or 0.0))
                    for name, row in engines.items()
                    if isinstance(row, dict)
                ]
                if low_p50:
                    slowest = sorted(low_p50, key=lambda item: item[1])[0]
                    if slowest[1] > 0 and slowest[1] < 90:
                        recommendations.append(
                            f"- P50 baixo em `{slowest[0]}` ({slowest[1]:.1f} chars/s): "
                            "priorize engine alternativa ou aumente paralelismo."
                        )

        if not recommendations:
            recommendations.append(
                "- Execução estável; manter perfil atual e repetir benchmark A/B."
            )

        content = [
            "# Runtime Recommendations",
            "",
            f"Generated at: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            "",
            *recommendations,
            "",
        ]
        out = metrics_path.with_name("metrics-recommendations.txt")
        with contextlib.suppress(Exception):
            out.write_text("\n".join(content), encoding="utf-8")
