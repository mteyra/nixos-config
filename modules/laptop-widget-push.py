"""laptop-widget-push: today's laptop screen time -> the iPhone widget (MP8).

Runs `laptop-report --json` for today since local midnight and keeps only:
  active_seconds, the top 3 apps (name + seconds) and updated_at.
No window titles, URLs or sites leave the laptop.

  laptop-widget-push --print   print the JSON, send nothing
  laptop-widget-push           PUT it to $LAPTOP_WIDGET_URL (…/laptop)

The token is read at run time from ~/.secrets/laptop-widget.token, so it is
never part of the Nix store or the repository.
"""

import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

REPORT = os.environ.get("LAPTOP_REPORT", "laptop-report")
TOKEN_FILE = Path.home() / ".secrets" / "laptop-widget.token"


def summary():
    now = datetime.now().astimezone()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    hours = max((now - midnight).total_seconds() / 3600, 1 / 60)
    out = subprocess.run(
        [REPORT, "--json", "--hours", f"{hours:.4f}"],
        check=True, capture_output=True, text=True,
    ).stdout
    report = json.loads(out)
    apps = sorted(report.get("apps") or [], key=lambda a: a["seconds"], reverse=True)
    return {
        "active_seconds": round(report.get("active_screen_seconds") or 0),
        "top_apps": [{"app": a["app"], "seconds": round(a["seconds"])} for a in apps[:3]],
        "updated_at": now.isoformat(timespec="seconds"),
    }


def push(payload):
    url = os.environ.get("LAPTOP_WIDGET_URL")
    if not url:
        sys.exit("LAPTOP_WIDGET_URL is not set")
    token = TOKEN_FILE.read_text().strip()
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        method="PUT",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "laptop-widget-push",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        print(f"pushed: HTTP {resp.status}, active {payload['active_seconds']} s")


def main():
    payload = summary()
    if "--print" in sys.argv[1:]:
        print(json.dumps(payload, indent=2))
    else:
        push(payload)


if __name__ == "__main__":
    main()
