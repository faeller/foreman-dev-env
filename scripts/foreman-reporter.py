#!/usr/bin/env python3
"""lightweight fact + report uploader for foreman"""

import json
import os
import socket
import time
import urllib.request
import urllib.error
from base64 import b64encode
from datetime import datetime, timezone

FOREMAN_URL = os.environ.get("FOREMAN_URL", "http://foreman:3000")
FOREMAN_USER = os.environ.get("FOREMAN_USER", "admin")
FOREMAN_PASSWORD = os.environ.get("FOREMAN_PASSWORD", "changeme")
REPORT_INTERVAL = int(os.environ.get("REPORT_INTERVAL", "120"))


def log(msg):
    print(f"[reporter] {msg}", flush=True)


def get_auth_header():
    credentials = b64encode(f"{FOREMAN_USER}:{FOREMAN_PASSWORD}".encode()).decode()
    return {"Authorization": f"Basic {credentials}", "Content-Type": "application/json"}


def read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except:
        return ""


def collect_facts():
    hostname = socket.getfqdn()

    # parse /etc/os-release
    os_info = {}
    if os.path.exists("/etc/os-release"):
        for line in read_file("/etc/os-release").split("\n"):
            if "=" in line:
                k, v = line.split("=", 1)
                os_info[k] = v.strip('"')

    # parse meminfo
    meminfo = {}
    for line in read_file("/proc/meminfo").split("\n"):
        if ":" in line:
            k, v = line.split(":", 1)
            meminfo[k.strip()] = int(v.strip().split()[0]) * 1024  # kb to bytes

    # uptime
    uptime = float(read_file("/proc/uptime").split()[0]) if os.path.exists("/proc/uptime") else 0

    # network
    ip = socket.gethostbyname(socket.gethostname()) if socket.gethostname() else ""
    mac = read_file("/sys/class/net/eth0/address")

    return {
        "_type": "foreman_dev",
        "_timestamp": datetime.now(timezone.utc).isoformat(),
        "fqdn": hostname,
        "hostname": hostname.split(".")[0],
        "domain": ".".join(hostname.split(".")[1:]) or "local",
        "ipaddress": ip,
        "macaddress": mac,
        "operatingsystem": os_info.get("ID", "linux").capitalize(),
        "operatingsystemrelease": os_info.get("VERSION_ID", ""),
        "osfamily": os_info.get("ID", "linux"),
        "kernel": "Linux",
        "kernelrelease": os.uname().release,
        "architecture": os.uname().machine,
        "processorcount": os.cpu_count() or 1,
        "memorysize_mb": meminfo.get("MemTotal", 0) // (1024 * 1024),
        "memoryfree_mb": meminfo.get("MemAvailable", 0) // (1024 * 1024),
        "uptime_seconds": int(uptime),
        "virtual": "docker",
        "is_virtual": True,
    }


def api_post(endpoint, data):
    url = f"{FOREMAN_URL}/api/{endpoint}"
    req = urllib.request.Request(url, data=json.dumps(data).encode(), headers=get_auth_header(), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": e.read().decode()}
    except Exception as e:
        return {"error": str(e)}


def upload_facts(facts):
    hostname = facts["fqdn"]
    return api_post("hosts/facts", {"name": hostname, "facts": facts})


def send_report():
    hostname = socket.getfqdn()
    return api_post("config_reports", {
        "config_report": {
            "host": hostname,
            "reported_at": datetime.now(timezone.utc).isoformat(),
            "status": {"applied": 0, "failed": 0, "failed_restarts": 0, "pending": 0, "restarted": 0, "skipped": 0},
            "metrics": {"time": {"total": 0.1}},
            "logs": [],
        }
    })


def run_once():
    log("collecting facts...")
    facts = collect_facts()

    log(f"uploading facts to {FOREMAN_URL}...")
    result = upload_facts(facts)
    if "error" in result:
        log(f"fact upload failed: {result['error']}")
    else:
        log("facts uploaded")

    log("sending config report...")
    result = send_report()
    if "error" in result:
        log(f"report failed: {result['error']}")
    else:
        log("report sent")


def main():
    import sys
    mode = sys.argv[1] if len(sys.argv) > 1 else "loop"

    if mode == "once":
        run_once()
    elif mode == "loop":
        log(f"starting reporter (interval: {REPORT_INTERVAL}s)")
        while True:
            run_once()
            time.sleep(REPORT_INTERVAL)
    else:
        print(f"usage: {sys.argv[0]} [once|loop]")
        sys.exit(1)


if __name__ == "__main__":
    main()
