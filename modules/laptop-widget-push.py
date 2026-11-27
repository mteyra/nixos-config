"""laptop-widget-push: today's laptop screen time -> the iPhone widget (MP8).

Runs nixcare's `laptop-report --json` for today since local midnight and keeps:
  active_seconds, the top 10 labels (nixcare's fixed list: listed sites,
  Claude Code, <terminal>-shell, app names) with seconds, active seconds per
  hour of today, yesterday's active time up to the same clock time, updated_at.
No window titles, URLs or unlisted sites leave the laptop.

Pushes only when the active time (or the day) changed since the last
successful push, so an idle laptop writes nothing.

  laptop-widget-push --print   print the JSON, send nothing
  laptop-widget-push           PUT it to $LAPTOP_WIDGET_URL if it changed
  laptop-widget-push --force   PUT it even if nothing changed

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
STATE_FILE = Path.home() / ".local" / "state" / "laptop-widget" / "last-push.json"
TOP_LABELS = 10


def report(hours):
    out = subprocess.run(
        [REPORT, "--json", "--hours", f"{hours:.4f}"],
        check=True, capture_output=True, text=True, timeout=60,
    ).stdout
    return json.loads(out)


# Window class -> the name you know the app by. Everything is then lowercase,
# with "-" instead of spaces ("Claude Code" -> "claude-code").
RENAMES = {
    "com.rtosta.zapzap": "whatsapp",
    "zapzap": "whatsapp",
    "vesktop": "discord",
    "MainKt": "blip",  # Blip (a Kotlin app) shows up by its main class
    "spring": "beyond-all-reason",  # the game runs on the Spring engine
    "code": "vscode",
    "Code": "vscode",
    "google-chrome": "chrome",
    "Google-chrome": "chrome",
    ".eduvpn-gui-wrapped": "eduvpn",
    "org.gnome.FileRoller": "file-roller",
    "com.gabm.satty": "satty",
}


def tidy(name):
    name = RENAMES.get(name, name).strip()
    if name.startswith("."):
        name = name[1:]
    if name.endswith("-wrapped"):
        name = name[: -len("-wrapped")]
    if name.count(".") >= 2 and " " not in name:  # reverse-DNS app id
        name = name.rsplit(".", 1)[1]
    return "-".join(name.lower().split())


def labels_of(rep):
    labels = rep.get("labels")
    if labels is None:  # nixcare without labels: fall back to app names
        labels = [{"label": a["app"], "seconds": a["seconds"]} for a in rep.get("apps") or []]
    sums = {}
    for x in labels:
        name = tidy(x["label"])
        sums[name] = sums.get(name, 0) + x["seconds"]
    top = sorted(sums.items(), key=lambda kv: kv[1], reverse=True)[:TOP_LABELS]
    return [{"label": name, "seconds": round(sec)} for name, sec in top if sec >= 30]


def hourly_of(rep, today):
    hours = [0] * 24
    for h in rep.get("hourly") or []:
        start = datetime.fromtimestamp(h["start"]).astimezone()
        if start.date() == today:
            hours[start.hour] += round(h["seconds"])
    return [min(3600, s) for s in hours]


def summary():
    now = datetime.now().astimezone()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    hours = max((now - midnight).total_seconds() / 3600, 1 / 60)
    today = report(hours)
    return now, {
        "active_seconds": round(today.get("active_screen_seconds") or 0),
        "labels": labels_of(today),
        "hourly": hourly_of(today, now.date()),
        "updated_at": now.isoformat(timespec="seconds"),
    }, hours


def yesterday_same_time(hours):
    # active(yesterday 00:00 .. now-24h) = active(last hours+24 h) - active(last 24 h)
    a = report(hours + 24).get("active_screen_seconds") or 0
    b = report(24).get("active_screen_seconds") or 0
    return max(0, round(a - b))


def changed(now, payload):
    try:
        last = json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return True
    return last.get("day") != now.date().isoformat() or last.get("active_seconds") != payload["active_seconds"]


def remember(now, payload):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps({"day": now.date().isoformat(), "active_seconds": payload["active_seconds"]}))


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
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(f"pushed: HTTP {resp.status}, active {payload['active_seconds']} s")


def main():
    args = sys.argv[1:]
    now, payload, hours = summary()
    if "--print" not in args and "--force" not in args and not changed(now, payload):
        print(f"unchanged ({payload['active_seconds']} s active), nothing pushed")
        return
    payload["yesterday_seconds"] = yesterday_same_time(hours)
    if "--print" in args:
        print(json.dumps(payload, indent=2))
        return
    push(payload)
    remember(now, payload)


if __name__ == "__main__":
    main()
