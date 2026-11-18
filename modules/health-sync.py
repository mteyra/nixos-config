"""Save Fitbit / Google Health data as local JSON files, one per type and day.

    health-sync                     # the last 7 days (what the timer runs)
    health-sync --days 30           # the last 30 days
    health-sync --since 2026-01-01  # everything since a date, in 30-day chunks

Files: <data dir>/<type>/<YYYY-MM-DD>.json, each a JSON list of data points as
ghealth prints them (simplified JSON). Days that are re-fetched are overwritten,
so running it again never duplicates anything. A missing file means no data was
recorded that day (device not worn or not synced), not a zero.

<data dir>/last-sync.json says when the last run happened and what it found.

Data dir: $HEALTH_DATA_DIR, default ~/.local/share/health.
ghealth:  $GHEALTH, default `ghealth` on PATH.
"""

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

GHEALTH = os.environ.get("GHEALTH", "ghealth")
DATA_DIR = Path(
    os.environ.get("HEALTH_DATA_DIR",
                   Path.home() / ".local" / "share" / "health")
)
CHUNK_DAYS = 30  # the API allows up to 90 days per request; stay well below

# (data type, ghealth operation, extra flags)
SOURCES = [
    ("steps", "daily-rollup", []),
    ("distance", "daily-rollup", []),
    ("floors", "daily-rollup", []),
    ("total-calories", "daily-rollup", []),
    ("active-minutes", "daily-rollup", []),
    ("active-zone-minutes", "daily-rollup", []),
    ("heart-rate", "daily-rollup", []),
    ("daily-resting-heart-rate", "list", []),
    ("daily-heart-rate-variability", "list", []),
    ("daily-oxygen-saturation", "list", []),
    ("daily-respiratory-rate", "list", []),
    ("daily-vo2-max", "list", []),
    ("daily-sleep-temperature-derivations", "list", []),
    ("sleep", "list", ["--detail"]),
    ("exercise", "list", []),
    ("weight", "list", []),
]


class AuthError(Exception):
    pass


def run_ghealth(args):
    """Run ghealth and return its parsed JSON output."""
    proc = subprocess.run([GHEALTH, *args], capture_output=True, text=True,
                          timeout=180)
    if proc.returncode == 0:
        return json.loads(proc.stdout or "{}")
    try:
        message = json.loads(proc.stderr or proc.stdout)["error"]["message"]
    except (ValueError, KeyError, TypeError):
        message = (proc.stderr or proc.stdout).strip()[:300]
    if proc.returncode in (2, 5):  # 2 = auth, 5 = not set up
        raise AuthError(message)
    raise RuntimeError(f"exit {proc.returncode}: {message}")


def fetch(data_type, operation, flags, start, end):
    """All data points of one type between two dates (inclusive)."""
    base = ["data", data_type, operation,
            "--from", start.isoformat(), "--to", end.isoformat(), *flags]
    if operation != "list":
        return run_ghealth(base).get("dataPoints", [])
    points, token = [], None
    while True:
        paging = ["--page-token", token] if token else []
        page = run_ghealth(base + ["--limit", "500"] + paging)
        points += page.get("dataPoints", [])
        token = page.get("nextPageToken")
        if not token:
            return points


def day_of(data_type, point):
    """The local day a data point belongs to (sleep counts for its wake day)."""
    keys = ["date", "end", "start", "time"] if data_type == "sleep" \
        else ["date", "start", "time", "end"]
    for key in keys:
        value = point.get(key)
        if isinstance(value, str) and len(value) >= 10:
            return value[:10]
    return None


def save(data_type, points):
    """Write points to one file per day; returns the number of days saved."""
    by_day = {}
    for point in points:
        day = day_of(data_type, point) or "undated"
        by_day.setdefault(day, []).append(point)
    folder = DATA_DIR / data_type
    folder.mkdir(parents=True, exist_ok=True)
    for day, day_points in by_day.items():
        target = folder / f"{day}.json"
        temporary = target.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(day_points, indent=1) + "\n")
        temporary.replace(target)
    return len(by_day)


def chunks(start, end):
    while start <= end:
        stop = min(start + dt.timedelta(days=CHUNK_DAYS - 1), end)
        yield start, stop
        start = stop + dt.timedelta(days=1)


def notify(title, body):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "Health sync", title, body],
                       check=False)


def main():
    parser = argparse.ArgumentParser(
        description="Save Google Health (Fitbit) data as local JSON files.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--days", type=int, default=7,
                       help="fetch the last N days (default 7)")
    group.add_argument("--since", type=dt.date.fromisoformat,
                       help="fetch everything since YYYY-MM-DD")
    args = parser.parse_args()

    today = dt.date.today()
    start = args.since or today - dt.timedelta(days=max(args.days, 1) - 1)
    summary = {"ran_at": dt.datetime.now().astimezone().isoformat(),
               "from": start.isoformat(), "to": today.isoformat(),
               "days_saved": {}, "errors": {}}

    try:
        for data_type, operation, flags in SOURCES:
            try:
                points = []
                for chunk_start, chunk_end in chunks(start, today):
                    points += fetch(data_type, operation, flags,
                                    chunk_start, chunk_end)
                summary["days_saved"][data_type] = save(data_type, points)
            except (RuntimeError, ValueError,
                    subprocess.TimeoutExpired) as error:
                summary["errors"][data_type] = str(error)
    except AuthError as error:
        summary["errors"]["login"] = str(error)
        notify("Health sync needs a new login",
               "Run: ghealth auth login")
        print(f"Not logged in: {error}\nRun: ghealth auth login",
              file=sys.stderr)

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "last-sync.json").write_text(
        json.dumps(summary, indent=1) + "\n")
    saved = sum(summary["days_saved"].values())
    print(f"Saved {saved} day files for {len(summary['days_saved'])} types "
          f"({start} to {today}) in {DATA_DIR}.")
    for data_type, error in summary["errors"].items():
        print(f"  {data_type}: {error}", file=sys.stderr)
    if "login" in summary["errors"]:
        return 2
    # Types the device doesn't record also show up as errors; only fail the
    # run when nothing at all could be fetched.
    return 0 if summary["days_saved"] else 1


if __name__ == "__main__":
    sys.exit(main())
