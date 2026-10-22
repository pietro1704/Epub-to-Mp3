"""Health metrics declarations for the retained CLI schema."""

def add_health_metrics_arguments(parser):
    parser.add_argument(
        "--health-check-interval-seconds",
        dest="health_check_interval_seconds",
        type=float,
        help="Healthcheck interval in seconds (server mode only)",
    )
    parser.add_argument(
        "--health-check-slow-edge-cps",
        dest="health_check_slow_edge_cps",
        type=float,
        help="Healthcheck Edge slow threshold (chars/s)",
    )
    parser.add_argument(
        "--health-check-slow-cps",
        dest="health_check_slow_cps",
        type=float,
        help="Healthcheck slow threshold for non-Edge engines (chars/s)",
    )
    parser.add_argument(
        "--health-check-high-cpu",
        dest="health_check_high_cpu",
        type=float,
        help="Healthcheck high CPU threshold (percent)",
    )
    parser.add_argument(
        "--health-check-high-mem",
        dest="health_check_high_mem",
        type=float,
        help="Healthcheck high memory threshold (percent)",
    )
    parser.add_argument(
        "--health-check-ok-cpu",
        dest="health_check_ok_cpu",
        type=float,
        help="Healthcheck OK CPU threshold (percent)",
    )
    parser.add_argument(
        "--health-check-ok-mem",
        dest="health_check_ok_mem",
        type=float,
        help="Healthcheck OK memory threshold (percent)",
    )
    parser.add_argument(
        "--health-check-slow-streak",
        dest="health_check_slow_streak",
        type=int,
        help="Healthcheck slow streak before reducing parallelism",
    )
    parser.add_argument(
        "--retry-failed",
        dest="retry_failed_rounds",
        metavar="N",
        type=int,
        help="Number of automatic retry rounds for failed chapters (default: auto). Use 0 to disable.",
    )
    parser.add_argument(
        "--retry-failed-manual",
        dest="retry_failed_manual",
        action="store_true",
        help="After auto retries, force one extra pass only for failed chapters.",
    )
    parser.add_argument(
        "--show-metrics-summary",
        dest="show_metrics_summary",
        action="store_true",
        help="Print runtime metrics summary from metrics-summary.json when conversion ends",
    )
    parser.add_argument(
        "--show-metrics-dashboard",
        dest="show_metrics_dashboard",
        action="store_true",
        help="Print metrics dashboard path (metrics-dashboard.html) when conversion ends",
    )
    parser.add_argument(
        "--open-metrics-dashboard",
        dest="open_metrics_dashboard",
        action="store_true",
        help="Open metrics-dashboard.html in default browser when conversion ends",
    )
    parser.add_argument(
        "--export-metrics-bundle",
        dest="export_metrics_bundle",
        action="store_true",
        help="Export metrics files into a ZIP bundle when conversion ends",
    )
