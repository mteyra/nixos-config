"""laptop-widget-push: today's laptop screen time -> the iPhone widget (MP8).

Runs nixcare's `laptop-report --json` for today since local midnight and keeps:
  active_seconds, the top 10 labels (nixcare's fixed list: listed sites,
  Claude Code, <terminal>-shell, app names) with seconds, active seconds per
  hour of today, yesterday's active time up to the same clock time, the last
  7 days' totals (remembered in the state file), updated_at.
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
from datetime import datetime, timedelta
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


def yesterday(hours, today_active):
    """(yesterday up to the same clock time, all of yesterday), in seconds."""
    since_yesterday = report(hours + 24).get("active_screen_seconds") or 0  # yesterday 00:00 .. now
    last_24h = report(24).get("active_screen_seconds") or 0
    same_time = max(0, round(since_yesterday - last_24h))
    whole_day = max(0, round(since_yesterday - today_active))
    return same_time, whole_day


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def changed(now, payload):
    last = load_state()
    return last.get("day") != now.date().isoformat() or last.get("active_seconds") != payload["active_seconds"]


def daily_totals(now, payload, yesterday_total):
    """Each day's total, remembered here (the daemon can't sum a whole week in
    one go). Today and yesterday come from the report; older days are what
    the last push of that day saw. Keeps two weeks."""
    days = load_state().get("days", {})
    days[(now.date() - timedelta(days=1)).isoformat()] = yesterday_total
    days[now.date().isoformat()] = payload["active_seconds"]
    return dict(sorted(days.items())[-14:])


def week_of(now, days):
    keys = [(now.date() - timedelta(days=n)).isoformat() for n in range(6, -1, -1)]
    return [{"day": k, "seconds": days.get(k)} for k in keys]


def remember(now, payload, days):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps({
        "day": now.date().isoformat(),
        "active_seconds": payload["active_seconds"],
        "days": days,
    }))


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
    payload["yesterday_seconds"], yesterday_total = yesterday(hours, payload["active_seconds"])
    days = daily_totals(now, payload, yesterday_total)
    payload["week"] = week_of(now, days)
    if "--print" in args:
        print(json.dumps(payload, indent=2))
        return
    push(payload)
    remember(now, payload, days)


if __name__ == "__main__":
    main()
