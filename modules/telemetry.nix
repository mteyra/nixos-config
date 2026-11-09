{ config, pkgs, lib, ... }:

# =============================================================================
# Local Screen-Time, Browser-Tab & Hardware-Potential Telemetry Stack
# =============================================================================
# 100 % local. Zero cloud services.
#
# Components:
#   1. ActivityWatch server (aw-server-rust) on 127.0.0.1:5600
#   2. Hyprland/Wayland window + idle watcher (awatcher)
#   3. Browser tab watchers (aw-watcher-web) declaratively installed into BOTH
#      Firefox (with automatic offline consent) and Google Chrome
#   4. Deep Hardware-Potential & Bottleneck Collector (laptop-telemetry.service)
#      - Samples every 5 s into /var/lib/laptop-telemetry/telemetry.db (SQLite WAL)
#      - Serves a live local dashboard & JSON API on http://127.0.0.1:5601
#   5. CLI analyzer (`laptop-report`) for terminal & agent-loop analysis.
# =============================================================================

let
  awatcherStart = pkgs.writeShellScript "awatcher-hyprland-start" ''
    set -u
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    for _ in $(seq 1 30); do
      wd=$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1 || true)
      hs=$(ls -d "$XDG_RUNTIME_DIR"/hypr/* 2>/dev/null | head -n1 || true)
      [ -n "$wd" ] && [ -n "$hs" ] && break
      sleep 1
    done
    [ -n "$wd" ] && export WAYLAND_DISPLAY="$(basename "$wd")"
    [ -n "$hs" ] && export HYPRLAND_INSTANCE_SIGNATURE="$(basename "$hs")"
    for _ in $(seq 1 20); do
      ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:5600/api/0/info >/dev/null 2>&1 && break
      sleep 0.5
    done
    exec ${pkgs.awatcher}/bin/awatcher
  '';

  collectorPy = pkgs.writeText "laptop-telemetry-daemon.py" ''
    #!/usr/bin/env python3
    import glob
    import http.server
    import json
    import os
    import socket
    import sqlite3
    import struct
    import threading
    import time
    import urllib.parse
    import urllib.request

    DB_PATH = "/var/lib/laptop-telemetry/telemetry.db"
    PORT = 5601
    SAMPLE_INTERVAL = 5.0
    CPU_ALLCORE_TURBO_MHZ = 3900.0
    CPU_SINGLE_TURBO_MHZ = 4200.0
    GPU_MAX_MHZ = 1150.0

    SCHEMA = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    CREATE TABLE IF NOT EXISTS samples (
      ts INTEGER PRIMARY KEY,
      dt REAL,
      cpu_busy_pct REAL,
      cpu_max_thread_pct REAL,
      cpu_avg_mhz REAL,
      cpu_max_mhz REAL,
      cpu_potential_pct REAL,
      load1 REAL,
      psi_cpu_some REAL,
      throttle_thermal INTEGER,
      throttle_prochot INTEGER,
      throttle_pwr INTEGER,
      top_cpu_comm TEXT,
      top_cpu_pct REAL,
      gpu_render_pct REAL,
      gpu_video_pct REAL,
      gpu_copy_pct REAL,
      gpu_freq_mhz REAL,
      top_gpu_comm TEXT,
      top_gpu_pct REAL,
      mem_used_pct REAL,
      mem_used_mib REAL,
      mem_avail_mib REAL,
      mem_cached_mib REAL,
      mem_shmem_mib REAL,
      zram_orig_mib REAL,
      zram_compr_mib REAL,
      zswap_mib REAL,
      psi_mem_some REAL,
      psi_mem_full REAL,
      top_mem_comm TEXT,
      top_mem_mib REAL,
      disk_read_kibs REAL,
      disk_write_kibs REAL,
      disk_busy_pct REAL,
      psi_io_some REAL,
      psi_io_full REAL,
      top_io_comm TEXT,
      top_io_write_kibs REAL,
      pkg_watts REAL,
      core_watts REAL,
      uncore_watts REAL,
      dram_watts REAL,
      rapl_pl1_watts REAL,
      cpu_temp_c REAL,
      nvme_temp_c REAL,
      ac_online INTEGER,
      power_profile TEXT,
      epp TEXT,
      bat_pct REAL,
      bat_watts REAL,
      bat_health_pct REAL,
      afk INTEGER,
      active_app TEXT,
      active_title TEXT,
      browser_domain TEXT,
      browser_url TEXT,
      browser_tab_title TEXT,
      browser_audible INTEGER,
      browser_tab_count INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);
    CREATE INDEX IF NOT EXISTS idx_samples_app ON samples(active_app);
    CREATE INDEX IF NOT EXISTS idx_samples_domain ON samples(browser_domain);
    """

    def read_text(path, default=""):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                return f.read().strip()
        except Exception:
            return default

    def read_int(path, default=0):
        s = read_text(path, "")
        try:
            return int(s)
        except Exception:
            return default

    def read_float(path, default=0.0):
        s = read_text(path, "")
        try:
            return float(s)
        except Exception:
            return default

    def read_psi(resource):
        txt = read_text("/proc/pressure/" + resource)
        some = 0.0
        full = 0.0
        for line in txt.splitlines():
            parts = line.split()
            if not parts:
                continue
            kind = parts[0]
            for kv in parts[1:]:
                if kv.startswith("avg10="):
                    try:
                        val = float(kv.split("=", 1)[1])
                        if kind == "some":
                            some = val
                        elif kind == "full":
                            full = val
                    except Exception:
                        pass
        return some, full

    def read_msr(reg):
        try:
            fd = os.open("/dev/cpu/0/msr", os.O_RDONLY)
            try:
                data = os.pread(fd, 8, reg)
                return struct.unpack("<Q", data)[0]
            finally:
                os.close(fd)
        except Exception:
            return None

    def read_cpu_jiffies():
        out = {}
        try:
            with open("/proc/stat", "r") as f:
                for line in f:
                    if not line.startswith("cpu"):
                        continue
                    parts = line.split()
                    name = parts[0]
                    vals = [int(x) for x in parts[1:]]
                    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
                    total = sum(vals)
                    busy = total - idle
                    out["total" if name == "cpu" else name] = (busy, total)
        except Exception:
            pass
        return out

    def read_cpu_freqs():
        freqs = []
        for p in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"):
            khz = read_int(p, 0)
            if khz > 0:
                freqs.append(khz / 1000.0)
        if not freqs:
            return 0.0, 0.0
        return sum(freqs) / len(freqs), max(freqs)

    def read_rapl_uj():
        res = {}
        for d in glob.glob("/sys/class/powercap/intel-rapl:0*"):
            name = read_text(os.path.join(d, "name"))
            uj = read_int(os.path.join(d, "energy_uj"), -1)
            if name and uj >= 0:
                res[name] = uj
        return res

    def read_temps():
        cpu_t = 0.0
        nvme_t = 0.0
        for tz in glob.glob("/sys/class/thermal/thermal_zone*"):
            ttype = read_text(os.path.join(tz, "type"))
            temp = read_int(os.path.join(tz, "temp"), 0) / 1000.0
            if ttype == "x86_pkg_temp":
                cpu_t = temp
            elif ttype == "SSD0":
                nvme_t = temp
        return cpu_t, nvme_t

    def read_mem():
        info = {}
        try:
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    if ":" in line:
                        k, v = line.split(":", 1)
                        parts = v.strip().split()
                        if parts:
                            info[k.strip()] = int(parts[0])
        except Exception:
            pass
        total_kib = info.get("MemTotal", 1)
        avail_kib = info.get("MemAvailable", total_kib)
        used_kib = max(0, total_kib - avail_kib)
        cached_kib = info.get("Cached", 0) + info.get("Buffers", 0) + info.get("SReclaimable", 0)
        shmem_kib = info.get("Shmem", 0)
        zswap_kib = info.get("Zswapped", 0)

        zram_orig_mib = 0.0
        zram_compr_mib = 0.0
        mm_stat = read_text("/sys/block/zram0/mm_stat")
        if mm_stat:
            parts = mm_stat.split()
            if len(parts) >= 2:
                try:
                    zram_orig_mib = int(parts[0]) / 1048576.0
                    zram_compr_mib = int(parts[1]) / 1048576.0
                except Exception:
                    pass
        return {
            "used_pct": (used_kib / total_kib) * 100.0,
            "used_mib": used_kib / 1024.0,
            "avail_mib": avail_kib / 1024.0,
            "cached_mib": cached_kib / 1024.0,
            "shmem_mib": shmem_kib / 1024.0,
            "zram_orig_mib": zram_orig_mib,
            "zram_compr_mib": zram_compr_mib,
            "zswap_mib": zswap_kib / 1024.0,
        }

    def read_nvme_stat():
        s = read_text("/sys/block/nvme0n1/stat")
        if not s:
            return None
        vals = [int(x) for x in s.split()]
        if len(vals) < 10:
            return None
        return {
            "rd_sectors": vals[2],
            "wr_sectors": vals[6],
            "io_ticks_ms": vals[9],
        }

    def scan_processes():
        clk_tck = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
        page_size = os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else 4096
        procs = {}
        drm_clients = {}
        for entry in os.scandir("/proc"):
            if not entry.name.isdigit():
                continue
            pid = int(entry.name)
            pdir = entry.path
            try:
                with open(pdir + "/stat", "r", encoding="utf-8", errors="replace") as f:
                    st = f.read()
                rparen = st.rfind(")")
                lparen = st.find("(")
                if lparen < 0 or rparen < 0:
                    continue
                comm = st[lparen + 1:rparen]
                rest = st[rparen + 2:].split()
                utime = int(rest[11])
                stime = int(rest[12])
                rss_pages = int(rest[21])
                cpu_sec = (utime + stime) / float(clk_tck)
                rss_mib = (rss_pages * page_size) / 1048576.0
            except Exception:
                continue

            wr_bytes = 0
            try:
                with open(pdir + "/io", "r") as f:
                    for line in f:
                        if line.startswith("write_bytes:"):
                            wr_bytes = int(line.split()[1])
                            break
            except Exception:
                pass

            procs[pid] = {
                "comm": comm,
                "cpu_sec": cpu_sec,
                "rss_mib": rss_mib,
                "wr_bytes": wr_bytes,
            }

            fdinfo_dir = pdir + "/fdinfo"
            try:
                for fde in os.scandir(fdinfo_dir):
                    try:
                        with open(fde.path, "r") as ff:
                            head = ff.read(512)
                        if "drm-client-id:" not in head:
                            continue
                        cid = None
                        render_ns = 0
                        video_ns = 0
                        copy_ns = 0
                        for line in head.splitlines():
                            if line.startswith("drm-client-id:"):
                                cid = line.split(":", 1)[1].strip()
                            elif line.startswith("drm-engine-render:"):
                                render_ns = int(line.split(":", 1)[1].split()[0])
                            elif line.startswith("drm-engine-video:") or line.startswith("drm-engine-video-enhance:"):
                                video_ns += int(line.split(":", 1)[1].split()[0])
                            elif line.startswith("drm-engine-copy:"):
                                copy_ns = int(line.split(":", 1)[1].split()[0])
                        if cid is not None and cid not in drm_clients:
                            drm_clients[cid] = {
                                "comm": comm,
                                "pid": pid,
                                "render_ns": render_ns,
                                "video_ns": video_ns,
                                "copy_ns": copy_ns,
                            }
                    except Exception:
                        continue
            except Exception:
                pass
        return procs, drm_clients

    def query_hyprland():
        socks = glob.glob("/run/user/*/hypr/*/.socket.sock")
        if not socks:
            return "", "", "", ""
        sock_path = socks[0]

        def ask(cmd):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(0.3)
                s.connect(sock_path)
                s.sendall(cmd.encode("utf-8"))
                chunks = []
                while True:
                    d = s.recv(8192)
                    if not d:
                        break
                    chunks.append(d)
                s.close()
                return json.loads(b"".join(chunks).decode("utf-8", errors="replace"))
            except Exception:
                return None

        aw = ask("j/activewindow") or {}
        app = str(aw.get("class") or aw.get("initialClass") or "")
        title = str(aw.get("title") or "")

        fallback_domain = ""
        fallback_tab = ""
        if app.lower() in ("firefox", "navigator", "google-chrome", "chromium"):
            for suffix in (" — Mozilla Firefox", " - Mozilla Firefox", " - Google Chrome", " - Chromium"):
                if title.endswith(suffix):
                    fallback_tab = title[:-len(suffix)].strip()
                    break
        return app, title, fallback_domain, fallback_tab

    def query_activitywatch():
        afk = 0
        domain = ""
        url = ""
        tab_title = ""
        audible = 0
        tab_count = 0
        try:
            req = urllib.request.Request("http://127.0.0.1:5600/api/0/buckets/", headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=0.4) as resp:
                buckets = json.loads(resp.read().decode("utf-8"))
        except Exception:
            return afk, domain, url, tab_title, audible, tab_count

        for bid in buckets:
            if bid.startswith("aw-watcher-afk"):
                try:
                    u = "http://127.0.0.1:5600/api/0/buckets/" + urllib.parse.quote(bid) + "/events?limit=1"
                    with urllib.request.urlopen(u, timeout=0.3) as r:
                        evs = json.loads(r.read().decode("utf-8"))
                        if evs:
                            st = evs[0].get("data", {}).get("status", "")
                            if st == "afk":
                                afk = 1
                except Exception:
                    pass

        best_ts = ""
        for bid in buckets:
            if bid.startswith("aw-watcher-web"):
                try:
                    u = "http://127.0.0.1:5600/api/0/buckets/" + urllib.parse.quote(bid) + "/events?limit=1"
                    with urllib.request.urlopen(u, timeout=0.3) as r:
                        evs = json.loads(r.read().decode("utf-8"))
                        if evs:
                            ev = evs[0]
                            ets = ev.get("timestamp", "")
                            if ets >= best_ts:
                                best_ts = ets
                                d = ev.get("data", {})
                                url = str(d.get("url") or "")
                                tab_title = str(d.get("title") or "")
                                audible = 1 if d.get("audible") else 0
                                tab_count = int(d.get("tabCount") or 0)
                                try:
                                    parsed = urllib.parse.urlparse(url)
                                    domain = parsed.netloc or ""
                                except Exception:
                                    domain = ""
                except Exception:
                    pass
        return afk, domain, url, tab_title, audible, tab_count

    def build_summary(conn, hours=24.0):
        since = int(time.time() - hours * 3600)
        cur = conn.cursor()
        cur.execute("""
          SELECT
            COUNT(*),
            COALESCE(SUM(dt), 0),
            COALESCE(SUM(CASE WHEN afk=0 THEN dt ELSE 0 END), 0),
            AVG(cpu_busy_pct), MAX(cpu_busy_pct),
            AVG(cpu_max_thread_pct), MAX(cpu_max_thread_pct),
            AVG(cpu_avg_mhz), MAX(cpu_max_mhz),
            AVG(cpu_potential_pct), MAX(cpu_potential_pct),
            AVG(gpu_render_pct), MAX(gpu_render_pct),
            AVG(gpu_video_pct), MAX(gpu_video_pct),
            AVG(gpu_freq_mhz), MAX(gpu_freq_mhz),
            AVG(mem_used_pct), MAX(mem_used_pct),
            MAX(mem_used_mib), MIN(mem_avail_mib),
            MAX(zram_orig_mib), MAX(zram_compr_mib), MAX(zswap_mib),
            AVG(disk_read_kibs), MAX(disk_read_kibs),
            AVG(disk_write_kibs), MAX(disk_write_kibs),
            AVG(disk_busy_pct), MAX(disk_busy_pct),
            AVG(psi_cpu_some), MAX(psi_cpu_some),
            AVG(psi_mem_some), MAX(psi_mem_some),
            AVG(psi_io_some), MAX(psi_io_some),
            AVG(pkg_watts), MAX(pkg_watts),
            AVG(cpu_temp_c), MAX(cpu_temp_c),
            MAX(throttle_thermal), MAX(throttle_prochot), MAX(throttle_pwr),
            AVG(bat_health_pct)
          FROM samples WHERE ts >= ?
        """, (since,))
        row = cur.fetchone()
        n = row[0] or 0

        cur.execute("SELECT * FROM samples ORDER BY ts DESC LIMIT 1")
        latest_row = cur.fetchone()
        cols = [d[0] for d in cur.description] if cur.description else []
        latest = dict(zip(cols, latest_row)) if latest_row else {}

        def p95(col):
            if n == 0:
                return 0.0
            offset = max(0, int(n * 0.95) - 1)
            cur.execute("SELECT " + col + " FROM samples WHERE ts >= ? ORDER BY " + col + " ASC LIMIT 1 OFFSET ?", (since, offset))
            r = cur.fetchone()
            return float(r[0] or 0.0) if r else 0.0

        cur.execute("""
          SELECT
            CASE WHEN LENGTH(active_app) = 0 THEN "(unfocused/desktop)" ELSE active_app END AS app,
            SUM(dt) AS sec,
            AVG(cpu_busy_pct) AS avg_cpu,
            AVG(cpu_potential_pct) AS avg_pot,
            AVG(gpu_render_pct + gpu_video_pct) AS avg_gpu,
            AVG(pkg_watts) AS avg_watts,
            AVG(disk_write_kibs) AS avg_wkibs
          FROM samples
          WHERE ts >= ? AND afk = 0
          GROUP BY app
          ORDER BY sec DESC
          LIMIT 20
        """, (since,))
        apps = [
            {
                "app": r[0], "seconds": round(r[1] or 0, 1),
                "avg_cpu_pct": round(r[2] or 0, 1),
                "avg_cpu_potential_pct": round(r[3] or 0, 1),
                "avg_gpu_pct": round(r[4] or 0, 1),
                "avg_watts": round(r[5] or 0, 2),
                "avg_write_kibs": round(r[6] or 0, 1),
            }
            for r in cur.fetchall()
        ]

        cur.execute("""
          SELECT
            CASE
              WHEN LENGTH(browser_domain) > 0 THEN browser_domain
              WHEN LENGTH(browser_tab_title) > 0 THEN browser_tab_title
              ELSE active_title
            END AS site,
            browser_tab_title,
            SUM(dt) AS sec,
            AVG(cpu_busy_pct) AS avg_cpu,
            AVG(gpu_render_pct + gpu_video_pct) AS avg_gpu,
            AVG(pkg_watts) AS avg_watts,
            SUM(CASE WHEN browser_audible=1 THEN dt ELSE 0 END) AS audible_sec
          FROM samples
          WHERE ts >= ? AND afk = 0
            AND (LOWER(active_app) IN ("firefox", "navigator", "google-chrome", "chromium") OR LENGTH(browser_domain) > 0)
          GROUP BY site
          ORDER BY sec DESC
          LIMIT 25
        """, (since,))
        tabs = [
            {
                "site": r[0] or "(browser)",
                "title": r[1] or "",
                "seconds": round(r[2] or 0, 1),
                "avg_cpu_pct": round(r[3] or 0, 1),
                "avg_gpu_pct": round(r[4] or 0, 1),
                "avg_watts": round(r[5] or 0, 2),
                "audible_seconds": round(r[6] or 0, 1),
            }
            for r in cur.fetchall()
        ]

        cur.execute("""
          SELECT top_cpu_comm, COUNT(*), AVG(top_cpu_pct), MAX(top_cpu_pct)
          FROM samples WHERE ts >= ? AND LENGTH(top_cpu_comm) > 0
          GROUP BY top_cpu_comm ORDER BY SUM(top_cpu_pct) DESC LIMIT 10
        """, (since,))
        top_cpu_procs = [
            {"comm": r[0], "samples": r[1], "avg_pct": round(r[2] or 0, 1), "max_pct": round(r[3] or 0, 1)}
            for r in cur.fetchall()
        ]

        cur.execute("""
          SELECT top_io_comm, COUNT(*), AVG(top_io_write_kibs), MAX(top_io_write_kibs)
          FROM samples WHERE ts >= ? AND LENGTH(top_io_comm) > 0 AND top_io_write_kibs > 0
          GROUP BY top_io_comm ORDER BY SUM(top_io_write_kibs) DESC LIMIT 10
        """, (since,))
        top_io_procs = [
            {"comm": r[0], "samples": r[1], "avg_kibs": round(r[2] or 0, 1), "max_kibs": round(r[3] or 0, 1)}
            for r in cur.fetchall()
        ]

        return {
            "window_hours": hours,
            "sample_count": n,
            "total_tracked_seconds": round(row[1] or 0, 1),
            "active_screen_seconds": round(row[2] or 0, 1),
            "latest": latest,
            "potential": {
                "cpu_busy": {"avg": round(row[3] or 0, 1), "p95": round(p95("cpu_busy_pct"), 1), "max": round(row[4] or 0, 1)},
                "cpu_single_thread": {"avg": round(row[5] or 0, 1), "p95": round(p95("cpu_max_thread_pct"), 1), "max": round(row[6] or 0, 1)},
                "cpu_freq_mhz": {"avg": round(row[7] or 0, 0), "max": round(row[8] or 0, 0), "ceiling": 4200},
                "cpu_true_potential": {"avg": round(row[9] or 0, 1), "p95": round(p95("cpu_potential_pct"), 1), "max": round(row[10] or 0, 1)},
                "gpu_render": {"avg": round(row[11] or 0, 1), "p95": round(p95("gpu_render_pct"), 1), "max": round(row[12] or 0, 1)},
                "gpu_video_decode": {"avg": round(row[13] or 0, 1), "p95": round(p95("gpu_video_pct"), 1), "max": round(row[14] or 0, 1)},
                "gpu_freq_mhz": {"avg": round(row[15] or 0, 0), "max": round(row[16] or 0, 0), "ceiling": 1150},
                "ram_pct": {"avg": round(row[17] or 0, 1), "p95": round(p95("mem_used_pct"), 1), "max": round(row[18] or 0, 1)},
                "ram_used_max_mib": round(row[19] or 0, 0),
                "ram_avail_min_mib": round(row[20] or 0, 0),
                "zram_orig_max_mib": round(row[21] or 0, 1),
                "zram_compr_max_mib": round(row[22] or 0, 1),
                "zswap_max_mib": round(row[23] or 0, 1),
                "nvme_read_kibs": {"avg": round(row[24] or 0, 1), "max": round(row[25] or 0, 1)},
                "nvme_write_kibs": {"avg": round(row[26] or 0, 1), "max": round(row[27] or 0, 1)},
                "nvme_busy_pct": {"avg": round(row[28] or 0, 1), "p95": round(p95("disk_busy_pct"), 1), "max": round(row[29] or 0, 1)},
                "psi_cpu_some": {"avg": round(row[30] or 0, 2), "max": round(row[31] or 0, 2)},
                "psi_mem_some": {"avg": round(row[32] or 0, 2), "max": round(row[33] or 0, 2)},
                "psi_io_some": {"avg": round(row[34] or 0, 2), "max": round(row[35] or 0, 2)},
                "pkg_watts": {"avg": round(row[36] or 0, 2), "p95": round(p95("pkg_watts"), 2), "max": round(row[37] or 0, 2), "sustained_ceiling": 15.0, "turbo_ceiling": 44.0},
                "cpu_temp_c": {"avg": round(row[38] or 0, 1), "max": round(row[39] or 0, 1), "throttle_ceiling": 97.0},
                "throttled_ever": {"thermal": bool(row[40]), "prochot": bool(row[41]), "power_limit": bool(row[42])},
                "battery_health_pct": round(row[43] or 0, 1),
            },
            "apps": apps,
            "browser_tabs": tabs,
            "top_cpu_processes": top_cpu_procs,
            "top_io_processes": top_io_procs,
        }

    DASHBOARD_HTML = """<!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>X1 Yoga — Hardware Potential & Screen Time</title>
      <style>
        :root {
          --bg: #0f172a; --card: #1e293b; --border: #334155;
          --text: #f8fafc; --muted: #94a3b8; --accent: #38bdf8;
        }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 24px; font-family: Inter, system-ui, sans-serif; background: var(--bg); color: var(--text); }
        h1 { margin: 0 0 6px 0; font-size: 22px; color: var(--accent); }
        .sub { color: var(--muted); font-size: 13px; margin-bottom: 20px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-bottom: 20px; }
        .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 16px; }
        .card h2 { margin: 0 0 12px 0; font-size: 15px; color: var(--accent); text-transform: uppercase; letter-spacing: 0.04em; }
        .metric { margin-bottom: 12px; }
        .metric-hdr { display: flex; justify-content: space-between; font-size: 13px; margin-bottom: 4px; }
        .bar-bg { height: 8px; background: #0b1120; border-radius: 4px; overflow: hidden; }
        .bar-fill { height: 100%; background: linear-gradient(90deg, #38bdf8, #818cf8); border-radius: 4px; transition: width 0.3s; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th, td { text-align: left; padding: 7px 8px; border-bottom: 1px solid var(--border); }
        th { color: var(--muted); font-weight: 600; }
        a { color: var(--accent); text-decoration: none; }
      </style>
    </head>
    <body>
      <h1>ThinkPad X1 Yoga Gen 3 — Hardware Potential & Screen Time</h1>
      <div class="sub" id="status">Loading telemetry... (100% local SQLite DB + ActivityWatch on <a href="http://127.0.0.1:5600" target="_blank">127.0.0.1:5600</a>)</div>
      <div class="grid" id="gauges"></div>
      <div class="grid">
        <div class="card">
          <h2>Screen Time & Energy by Application</h2>
          <table id="apps-table"><thead><tr><th>App</th><th>Time</th><th>CPU %</th><th>GPU %</th><th>Avg W</th></tr></thead><tbody></tbody></table>
        </div>
        <div class="card">
          <h2>Browser Tabs / Sites (Firefox & Chrome)</h2>
          <table id="tabs-table"><thead><tr><th>Site / Tab</th><th>Time</th><th>CPU %</th><th>GPU %</th><th>Audio</th></tr></thead><tbody></tbody></table>
        </div>
      </div>
      <div class="grid">
        <div class="card">
          <h2>Top CPU Processes</h2>
          <table id="cpu-table"><thead><tr><th>Process</th><th>Avg CPU %</th><th>Peak CPU %</th></tr></thead><tbody></tbody></table>
        </div>
        <div class="card">
          <h2>Top Disk Writers</h2>
          <table id="io-table"><thead><tr><th>Process</th><th>Avg Write</th><th>Peak Write</th></tr></thead><tbody></tbody></table>
        </div>
      </div>
      <script>
        function fmtDur(s) {
          if (s < 60) return Math.round(s) + "s";
          if (s < 3600) return Math.floor(s/60) + "m " + Math.round(s%60) + "s";
          return Math.floor(s/3600) + "h " + Math.floor((s%3600)/60) + "m";
        }
        function bar(label, cur, avg, max, unit) {
          var u = unit || "%";
          var pct = Math.min(100, Math.max(0, cur));
          return '<div class="metric">' +
            '<div class="metric-hdr"><span>' + label + '</span><span><b>' + cur + u + '</b> (avg ' + avg + u + ', peak ' + max + u + ')</span></div>' +
            '<div class="bar-bg"><div class="bar-fill" style="width:' + pct + '%"></div></div>' +
          '</div>';
        }
        async function refresh() {
          var r = await fetch("/api/summary?hours=24");
          var d = await r.json();
          var L = d.latest || {};
          var P = d.potential;
          document.getElementById("status").innerHTML =
            "Samples: <b>" + d.sample_count + "</b> | Active screen time: <b>" + fmtDur(d.active_screen_seconds) + "</b> | " +
            "Profile: <b>" + (L.power_profile || "?") + "</b> (" + (L.epp || "?") + ") | Focused: <b>" + (L.active_app || "none") + "</b> | " +
            'Raw ActivityWatch UI: <a href="http://127.0.0.1:5600" target="_blank">127.0.0.1:5600</a>';
          document.getElementById("gauges").innerHTML =
            '<div class="card">' +
              '<h2>CPU Potential (i7-8650U 4C/8T)</h2>' +
              bar("True Compute Potential (vs 3.9 GHz Turbo)", (L.cpu_potential_pct||0).toFixed(1), P.cpu_true_potential.avg, P.cpu_true_potential.max) +
              bar("Thread Busy (all 8 threads)", (L.cpu_busy_pct||0).toFixed(1), P.cpu_busy.avg, P.cpu_busy.max) +
              bar("Busiest Single Thread (single-core ceiling)", (L.cpu_max_thread_pct||0).toFixed(1), P.cpu_single_thread.avg, P.cpu_single_thread.max) +
              '<div class="sub">Clock: <b>' + Math.round(L.cpu_avg_mhz||0) + ' MHz</b> (peak ' + P.cpu_freq_mhz.max + ' / 4200 MHz) | Top: <b>' + (L.top_cpu_comm||"-") + '</b></div>' +
            '</div>' +
            '<div class="card">' +
              '<h2>GPU Potential (Intel UHD 620)</h2>' +
              bar("3D / Render Engine (Compositor / WebGL)", (L.gpu_render_pct||0).toFixed(1), P.gpu_render.avg, P.gpu_render.max) +
              bar("Hardware Video Decode (VA-API QuickSync)", (L.gpu_video_pct||0).toFixed(1), P.gpu_video_decode.avg, P.gpu_video_decode.max) +
              '<div class="sub">GPU Clock: <b>' + Math.round(L.gpu_freq_mhz||0) + ' MHz</b> / 1150 MHz | Top GPU: <b>' + (L.top_gpu_comm||"-") + '</b></div>' +
            '</div>' +
            '<div class="card">' +
              '<h2>RAM & Compressed Swap (16 GiB)</h2>' +
              bar("RAM Used (excl. reclaimable cache)", (L.mem_used_pct||0).toFixed(1), P.ram_pct.avg, P.ram_pct.max) +
              '<div class="sub">Used: <b>' + Math.round(L.mem_used_mib||0) + ' MiB</b> | Avail: <b>' + Math.round(L.mem_avail_mib||0) + ' MiB</b> | zram: <b>' + (L.zram_orig_mib||0).toFixed(0) + "→" + (L.zram_compr_mib||0).toFixed(0) + ' MiB</b> | zswap: <b>' + (L.zswap_mib||0).toFixed(0) + ' MiB</b></div>' +
            '</div>' +
            '<div class="card">' +
              '<h2>Power, Thermal & NVMe I/O</h2>' +
              bar("NVMe Busy %", (L.disk_busy_pct||0).toFixed(1), P.nvme_busy_pct.avg, P.nvme_busy_pct.max) +
              '<div class="sub">CPU Power: <b>' + (L.pkg_watts||0).toFixed(1) + ' W</b> (avg ' + P.pkg_watts.avg + ' W, peak ' + P.pkg_watts.max + ' W) | Temp: <b>' + (L.cpu_temp_c||0).toFixed(0) + '°C</b> (max ' + P.cpu_temp_c.max + '°C / 97°C) | Battery Health: <b>' + P.battery_health_pct + '%</b></div>' +
            '</div>';
          document.querySelector("#apps-table tbody").innerHTML = d.apps.map(function(a) {
            return "<tr><td><b>" + a.app + "</b></td><td>" + fmtDur(a.seconds) + "</td><td>" + a.avg_cpu_pct + "%</td><td>" + a.avg_gpu_pct + "%</td><td>" + a.avg_watts + "W</td></tr>";
          }).join("");
          document.querySelector("#tabs-table tbody").innerHTML = d.browser_tabs.map(function(t) {
            return '<tr><td title="' + t.title + '"><b>' + t.site.slice(0,48) + "</b></td><td>" + fmtDur(t.seconds) + "</td><td>" + t.avg_cpu_pct + "%</td><td>" + t.avg_gpu_pct + "%</td><td>" + fmtDur(t.audible_seconds) + "</td></tr>";
          }).join("");
          document.querySelector("#cpu-table tbody").innerHTML = d.top_cpu_processes.map(function(p) {
            return "<tr><td><b>" + p.comm + "</b></td><td>" + p.avg_pct + "%</td><td>" + p.max_pct + "%</td></tr>";
          }).join("");
          document.querySelector("#io-table tbody").innerHTML = d.top_io_processes.map(function(p) {
            return "<tr><td><b>" + p.comm + "</b></td><td>" + p.avg_kibs + " KiB/s</td><td>" + p.max_kibs + " KiB/s</td></tr>";
          }).join("");
        }
        refresh();
        setInterval(refresh, 5000);
      </script>
    </body>
    </html>
    """

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/api/summary":
                qs = urllib.parse.parse_qs(parsed.query)
                hours = float(qs.get("hours", ["24"])[0])
                conn = sqlite3.connect("file:" + DB_PATH + "?mode=ro", uri=True)
                try:
                    data = build_summary(conn, hours)
                finally:
                    conn.close()
                body = json.dumps(data, indent=2).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                body = DASHBOARD_HTML.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

    def serve_http():
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
        srv.serve_forever()

    def main():
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        conn = sqlite3.connect(DB_PATH)
        conn.executescript(SCHEMA)
        conn.commit()
        try:
            os.chmod(DB_PATH, 0o644)
        except Exception:
            pass

        t = threading.Thread(target=serve_http, daemon=True)
        t.start()

        prev_ts = time.time()
        prev_jiff = read_cpu_jiffies()
        prev_rapl = read_rapl_uj()
        prev_nvme = read_nvme_stat()
        prev_procs, prev_drm = scan_processes()

        while True:
            time.sleep(SAMPLE_INTERVAL)
            now = time.time()
            dt = max(0.5, now - prev_ts)

            cur_jiff = read_cpu_jiffies()
            cur_rapl = read_rapl_uj()
            cur_nvme = read_nvme_stat()
            cur_procs, cur_drm = scan_processes()

            cpu_busy_pct = 0.0
            if "total" in cur_jiff and "total" in prev_jiff:
                db = cur_jiff["total"][0] - prev_jiff["total"][0]
                dtot = cur_jiff["total"][1] - prev_jiff["total"][1]
                if dtot > 0:
                    cpu_busy_pct = min(100.0, max(0.0, (db / dtot) * 100.0))

            cpu_max_thread_pct = 0.0
            for k, v in cur_jiff.items():
                if k == "total" or k not in prev_jiff:
                    continue
                db = v[0] - prev_jiff[k][0]
                dtot = v[1] - prev_jiff[k][1]
                if dtot > 0:
                    pct = min(100.0, max(0.0, (db / dtot) * 100.0))
                    if pct > cpu_max_thread_pct:
                        cpu_max_thread_pct = pct

            avg_mhz, max_mhz = read_cpu_freqs()
            cpu_potential_pct = min(100.0, cpu_busy_pct * (avg_mhz / CPU_ALLCORE_TURBO_MHZ))
            try:
                load1 = float(read_text("/proc/loadavg", "0").split()[0])
            except Exception:
                load1 = 0.0

            psi_cpu_some, _ = read_psi("cpu")
            psi_mem_some, psi_mem_full = read_psi("memory")
            psi_io_some, psi_io_full = read_psi("io")

            therm_msr = read_msr(0x1B1)
            limit_msr = read_msr(0x64F)
            throttle_thermal = 1 if (therm_msr is not None and (therm_msr & 0x1)) else 0
            throttle_prochot = 1 if (therm_msr is not None and (therm_msr & 0x4)) else 0
            throttle_pwr = 1 if (therm_msr is not None and (therm_msr & 0x400)) else 0
            if limit_msr is not None and (limit_msr & 0x1C00):
                throttle_pwr = 1

            top_cpu_comm, top_cpu_pct = "", 0.0
            top_io_comm, top_io_write_kibs = "", 0.0
            top_mem_comm, top_mem_mib = "", 0.0

            cpu_by_comm = {}
            io_by_comm = {}
            mem_by_comm = {}

            for pid, pinfo in cur_procs.items():
                comm = pinfo["comm"]
                mem_by_comm[comm] = mem_by_comm.get(comm, 0.0) + pinfo["rss_mib"]
                if pid in prev_procs and prev_procs[pid]["comm"] == comm:
                    dcpu = max(0.0, pinfo["cpu_sec"] - prev_procs[pid]["cpu_sec"])
                    cpu_by_comm[comm] = cpu_by_comm.get(comm, 0.0) + (dcpu / dt) * 100.0
                    dwr = max(0, pinfo["wr_bytes"] - prev_procs[pid]["wr_bytes"])
                    io_by_comm[comm] = io_by_comm.get(comm, 0.0) + (dwr / 1024.0) / dt

            if cpu_by_comm:
                top_cpu_comm, top_cpu_pct = max(cpu_by_comm.items(), key=lambda x: x[1])
            if io_by_comm:
                top_io_comm, top_io_write_kibs = max(io_by_comm.items(), key=lambda x: x[1])
            if mem_by_comm:
                top_mem_comm, top_mem_mib = max(mem_by_comm.items(), key=lambda x: x[1])

            render_ns_delta = 0
            video_ns_delta = 0
            copy_ns_delta = 0
            gpu_by_comm = {}
            for cid, cinfo in cur_drm.items():
                if cid in prev_drm:
                    dr = max(0, cinfo["render_ns"] - prev_drm[cid]["render_ns"])
                    dv = max(0, cinfo["video_ns"] - prev_drm[cid]["video_ns"])
                    dc = max(0, cinfo["copy_ns"] - prev_drm[cid]["copy_ns"])
                    render_ns_delta += dr
                    video_ns_delta += dv
                    copy_ns_delta += dc
                    comm = cinfo["comm"]
                    gpu_by_comm[comm] = gpu_by_comm.get(comm, 0.0) + ((dr + dv) / (dt * 1e9)) * 100.0

            gpu_render_pct = min(100.0, (render_ns_delta / (dt * 1e9)) * 100.0)
            gpu_video_pct = min(100.0, (video_ns_delta / (dt * 1e9)) * 100.0)
            gpu_copy_pct = min(100.0, (copy_ns_delta / (dt * 1e9)) * 100.0)
            gpu_freq_mhz = read_float("/sys/class/drm/card1/gt_act_freq_mhz", 0.0)
            top_gpu_comm, top_gpu_pct = ("", 0.0)
            if gpu_by_comm:
                top_gpu_comm, top_gpu_pct = max(gpu_by_comm.items(), key=lambda x: x[1])

            mem = read_mem()

            disk_read_kibs = 0.0
            disk_write_kibs = 0.0
            disk_busy_pct = 0.0
            if cur_nvme and prev_nvme:
                dr_sec = max(0, cur_nvme["rd_sectors"] - prev_nvme["rd_sectors"])
                dw_sec = max(0, cur_nvme["wr_sectors"] - prev_nvme["wr_sectors"])
                dticks = max(0, cur_nvme["io_ticks_ms"] - prev_nvme["io_ticks_ms"])
                disk_read_kibs = (dr_sec * 512.0 / 1024.0) / dt
                disk_write_kibs = (dw_sec * 512.0 / 1024.0) / dt
                disk_busy_pct = min(100.0, (dticks / (dt * 1000.0)) * 100.0)

            def rapl_w(key):
                if key in cur_rapl and key in prev_rapl:
                    duj = cur_rapl[key] - prev_rapl[key]
                    if duj >= 0:
                        return (duj / 1e6) / dt
                return 0.0

            pkg_watts = rapl_w("package-0")
            core_watts = rapl_w("core")
            uncore_watts = rapl_w("uncore")
            dram_watts = rapl_w("dram")
            rapl_pl1_watts = read_int("/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw", 44000000) / 1e6

            cpu_temp_c, nvme_temp_c = read_temps()
            ac_online = read_int("/sys/class/power_supply/AC/online", 0)
            power_profile = ""
            for line in read_text("/var/lib/power-profiles-daemon/state.ini").splitlines():
                if line.startswith("Profile="):
                    power_profile = line.split("=", 1)[1].strip()
            epp = read_text("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference", "")

            bat_pct = read_float("/sys/class/power_supply/BAT0/capacity", 0.0)
            bat_watts = read_int("/sys/class/power_supply/BAT0/power_now", 0) / 1e6
            efull = read_float("/sys/class/power_supply/BAT0/energy_full", 0.0)
            edesign = read_float("/sys/class/power_supply/BAT0/energy_full_design", 54060000.0)
            bat_health_pct = (efull / edesign * 100.0) if edesign > 0 else 0.0

            active_app, active_title, fb_domain, fb_tab = query_hyprland()
            afk, aw_domain, aw_url, aw_tab_title, aw_audible, aw_tab_count = query_activitywatch()

            browser_domain = aw_domain if aw_domain else fb_domain
            browser_tab_title = aw_tab_title if aw_tab_title else fb_tab

            row_vals = (
                int(now), round(dt, 2),
                round(cpu_busy_pct, 2), round(cpu_max_thread_pct, 2),
                round(avg_mhz, 1), round(max_mhz, 1), round(cpu_potential_pct, 2),
                round(load1, 2), round(psi_cpu_some, 2),
                throttle_thermal, throttle_prochot, throttle_pwr,
                top_cpu_comm, round(top_cpu_pct, 1),
                round(gpu_render_pct, 2), round(gpu_video_pct, 2), round(gpu_copy_pct, 2),
                round(gpu_freq_mhz, 1), top_gpu_comm, round(top_gpu_pct, 1),
                round(mem["used_pct"], 2), round(mem["used_mib"], 1), round(mem["avail_mib"], 1),
                round(mem["cached_mib"], 1), round(mem["shmem_mib"], 1),
                round(mem["zram_orig_mib"], 2), round(mem["zram_compr_mib"], 2), round(mem["zswap_mib"], 2),
                round(psi_mem_some, 2), round(psi_mem_full, 2),
                top_mem_comm, round(top_mem_mib, 1),
                round(disk_read_kibs, 1), round(disk_write_kibs, 1), round(disk_busy_pct, 2),
                round(psi_io_some, 2), round(psi_io_full, 2),
                top_io_comm, round(top_io_write_kibs, 1),
                round(pkg_watts, 2), round(core_watts, 2), round(uncore_watts, 2), round(dram_watts, 2),
                round(rapl_pl1_watts, 1), round(cpu_temp_c, 1), round(nvme_temp_c, 1),
                ac_online, power_profile, epp,
                round(bat_pct, 1), round(bat_watts, 2), round(bat_health_pct, 1),
                afk, active_app, active_title,
                browser_domain, aw_url, browser_tab_title, aw_audible, aw_tab_count
            )
            placeholders = ",".join(["?"] * len(row_vals))
            conn.execute("INSERT OR REPLACE INTO samples VALUES (" + placeholders + ")", row_vals)
            conn.commit()

            prev_ts = now
            prev_jiff = cur_jiff
            prev_rapl = cur_rapl
            prev_nvme = cur_nvme
            prev_procs = cur_procs
            prev_drm = cur_drm

    if __name__ == "__main__":
        main()
  '';

  laptopReportBin = pkgs.writeScriptBin "laptop-report" ''
    #!${pkgs.python3}/bin/python3
    import argparse
    import json
    import sys
    import urllib.request

    def fmt_dur(s):
        s = int(round(s))
        if s < 60:
            return str(s) + "s"
        if s < 3600:
            return str(s // 60) + "m " + ("%02ds" % (s % 60))
        return str(s // 3600) + "h " + ("%02dm" % ((s % 3600) // 60))

    def main():
        ap = argparse.ArgumentParser(description="Laptop Hardware Potential & Screen Time Report")
        ap.add_argument("--hours", type=float, default=24.0, help="Lookback window in hours (default: 24)")
        ap.add_argument("--json", action="store_true", help="Print raw JSON summary")
        args = ap.parse_args()

        url = "http://127.0.0.1:5601/api/summary?hours=" + str(args.hours)
        try:
            with urllib.request.urlopen(url, timeout=3.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            print("Error querying laptop-telemetry daemon at " + url + ": " + str(e), file=sys.stderr)
            sys.exit(1)

        if args.json:
            print(json.dumps(data, indent=2))
            return

        P = data["potential"]
        L = data.get("latest") or {}
        print("=" * 78)
        print(" THINKPAD X1 YOGA GEN 3 — HARDWARE POTENTIAL & SCREEN TIME (last %gh)" % args.hours)
        print("=" * 78)
        print(" Samples: %d  |  Tracked: %s  |  Active screen time: %s" % (
            data["sample_count"], fmt_dur(data["total_tracked_seconds"]), fmt_dur(data["active_screen_seconds"])))
        print(" Power profile: %s (EPP=%s, AC=%s)  |  Battery health: %s%%" % (
            L.get("power_profile", "?"), L.get("epp", "?"), L.get("ac_online", 0), P["battery_health_pct"]))
        print("-" * 78)
        print(" HARDWARE POTENTIAL UTILIZATION (How much of your laptop ceiling you use)")
        print("  CPU True Compute (vs 3.9GHz 4C/8T) : cur %5.1f%% | avg %5.1f%% | p95 %5.1f%% | peak %5.1f%%" % (
            L.get("cpu_potential_pct", 0), P["cpu_true_potential"]["avg"], P["cpu_true_potential"]["p95"], P["cpu_true_potential"]["max"]))
        print("  CPU Thread Busy (all 8 threads)    : cur %5.1f%% | avg %5.1f%% | p95 %5.1f%% | peak %5.1f%%" % (
            L.get("cpu_busy_pct", 0), P["cpu_busy"]["avg"], P["cpu_busy"]["p95"], P["cpu_busy"]["max"]))
        print("  CPU Busiest Single Thread (1T max) : cur %5.1f%% | avg %5.1f%% | p95 %5.1f%% | peak %5.1f%%" % (
            L.get("cpu_max_thread_pct", 0), P["cpu_single_thread"]["avg"], P["cpu_single_thread"]["p95"], P["cpu_single_thread"]["max"]))
        print("  CPU Clocks (ceiling 4200 MHz)      : cur %5.0f MHz | avg %5.0f MHz | peak %5.0f MHz" % (
            L.get("cpu_avg_mhz", 0), P["cpu_freq_mhz"]["avg"], P["cpu_freq_mhz"]["max"]))
        print("  GPU 3D/Render (UHD 620 compositor) : cur %5.1f%% | avg %5.1f%% | p95 %5.1f%% | peak %5.1f%%" % (
            L.get("gpu_render_pct", 0), P["gpu_render"]["avg"], P["gpu_render"]["p95"], P["gpu_render"]["max"]))
        print("  GPU Video Decode (VA-API QuickSync): cur %5.1f%% | avg %5.1f%% | p95 %5.1f%% | peak %5.1f%%" % (
            L.get("gpu_video_pct", 0), P["gpu_video_decode"]["avg"], P["gpu_video_decode"]["p95"], P["gpu_video_decode"]["max"]))
        print("  RAM Used (of 15.5 GiB usable)      : cur %5.1f%% | avg %5.1f%% | p95 %5.1f%% | peak %5.1f%% (min avail %.0f MiB)" % (
            L.get("mem_used_pct", 0), P["ram_pct"]["avg"], P["ram_pct"]["p95"], P["ram_pct"]["max"], P["ram_avail_min_mib"]))
        print("  Compressed Swap (zram / zswap)     : zram %.0f->%.0f MiB | zswap %.0f MiB" % (
            L.get("zram_orig_mib", 0), L.get("zram_compr_mib", 0), L.get("zswap_mib", 0)))
        print("  NVMe Disk Busy & Write Rate        : busy avg %4.1f%% (peak %4.1f%%) | write avg %6.1f KiB/s (peak %6.1f KiB/s)" % (
            P["nvme_busy_pct"]["avg"], P["nvme_busy_pct"]["max"], P["nvme_write_kibs"]["avg"], P["nvme_write_kibs"]["max"]))
        print("  Package Power & Thermal Headroom   : %4.1f W (avg %4.1f W, peak %4.1f W / 44W) | %4.0f C (peak %4.0f C / 97 C)" % (
            L.get("pkg_watts", 0), P["pkg_watts"]["avg"], P["pkg_watts"]["max"], L.get("cpu_temp_c", 0), P["cpu_temp_c"]["max"]))
        print("  Kernel PSI Stalls (CPU / Mem / IO) : CPU avg %.2f%% | Mem avg %.2f%% | IO avg %.2f%%" % (
            P["psi_cpu_some"]["avg"], P["psi_mem_some"]["avg"], P["psi_io_some"]["avg"]))
        print("-" * 78)
        print(" SCREEN TIME & HARDWARE COST BY APPLICATION")
        for a in data["apps"][:12]:
            print("  %-28s  %8s  | CPU %5.1f%% (pot %4.1f%%) | GPU %4.1f%% | %4.1f W" % (
                a["app"][:28], fmt_dur(a["seconds"]), a["avg_cpu_pct"], a["avg_cpu_potential_pct"], a["avg_gpu_pct"], a["avg_watts"]))
        print("-" * 78)
        print(" SCREEN TIME BY BROWSER TAB / SITE (Firefox & Chrome)")
        if not data["browser_tabs"]:
            print("  (No active browser focus recorded in window yet)")
        for t in data["browser_tabs"][:12]:
            print("  %-42s  %8s  | CPU %4.1f%% | GPU %4.1f%% | %4.1f W" % (
                t["site"][:42], fmt_dur(t["seconds"]), t["avg_cpu_pct"], t["avg_gpu_pct"], t["avg_watts"]))
        print("-" * 78)
        print(" Dashboards: http://127.0.0.1:5601 (Hardware Potential + Screen Time) | http://127.0.0.1:5600 (ActivityWatch)")
        print("=" * 78)

    if __name__ == "__main__":
        main()
  '';
in
{
  # 1. Local ActivityWatch server (aw-server-rust) on 127.0.0.1:5600
  systemd.user.services.aw-server-rust = {
    description = "ActivityWatch local time-tracking server (Rust)";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.aw-server-rust}/bin/aw-server --host 127.0.0.1 --port 5600";
      Restart = "always";
      RestartSec = 2;
    };
  };

  # 2. Native Hyprland/Wayland window & idle tracker (awatcher)
  systemd.user.services.awatcher = {
    description = "ActivityWatch Wayland/Hyprland window and idle watcher";
    after = [ "aw-server-rust.service" ];
    wants = [ "aw-server-rust.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = awatcherStart;
      Restart = "always";
      RestartSec = 3;
    };
  };

  # 3. Declarative browser tab tracking (aw-watcher-web) for Firefox AND Google Chrome
  programs.firefox.policies = {
    ExtensionSettings = {
      "{ef87d84c-2127-493f-b952-5b4e744245bc}" = {
        installation_mode = "force_installed";
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/aw-watcher-web/latest.xpi";
      };
    };
    "3rdparty".Extensions."{ef87d84c-2127-493f-b952-5b4e744245bc}" = {
      consentOfflineDataCollection = true;
    };
  };

  programs.chromium = {
    enable = true;
    extensions = [
      "nglaklhklhcoonedhgnpgddginnjdadi;https://clients2.google.com/service/update2/crx"
    ];
  };

  # 4. System-wide Hardware Potential & Screen-Time Telemetry Collector + Web UI (127.0.0.1:5601)
  systemd.services.laptop-telemetry = {
    description = "Laptop Hardware Potential & Screen-Time Telemetry Daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStartPre = "-${pkgs.kmod}/bin/modprobe msr";
      ExecStart = "${pkgs.python3}/bin/python3 ${collectorPy}";
      StateDirectory = "laptop-telemetry";
      StateDirectoryMode = "0755";
      UMask = "0022";
      Restart = "always";
      RestartSec = 2;
    };
  };

  # 5. CLI tools in PATH
  environment.systemPackages = [
    pkgs.aw-server-rust
    pkgs.awatcher
    laptopReportBin
  ];
}
