#!/usr/bin/env python3
"""Grok OAuth expiry helper. Never prints tokens, refresh_token, or email.

Default (watchdog contract): print 1 if expired, 0 otherwise.
  python3 token-expired.py /path/to/auth.json

Probe (M1): print exists/has_key/expires_at/seconds_left/status. No secrets.
  python3 token-expired.py --probe /path/to/auth.json
  exit 0 ok, 1 soon (<2h), 2 expired/missing
"""
import datetime
import json
import sys
from pathlib import Path

SOON_SECONDS = 7200  # 2 hours — documented in docs/GROK_AUTH_KEEPALIVE.md


def parse_expires(exp):
    if exp is None or exp == "":
        return None
    try:
        if isinstance(exp, (int, float)):
            ts = float(exp)
            if ts > 1e12:
                ts /= 1000.0
            return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
        dt = datetime.datetime.fromisoformat(str(exp).replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt
    except Exception:
        return None


def pick_entry(data):
    if not isinstance(data, dict):
        return None
    for k, v in data.items():
        if isinstance(v, dict) and v.get("key") and (
            "auth.x.ai" in str(k) or v.get("auth_mode") == "oidc"
        ):
            return v
    for v in data.values():
        if isinstance(v, dict) and v.get("key"):
            return v
    return None


def load_data(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def default_mode(path):
    data = load_data(path)
    if not isinstance(data, dict):
        print("0")
        return
    now = datetime.datetime.now(datetime.timezone.utc)
    expired = False
    for entry in data.values():
        if not isinstance(entry, dict):
            continue
        dt = parse_expires(entry.get("expires_at") or entry.get("expiresAt"))
        if dt is None:
            continue
        if dt < now:
            expired = True
            break
    print("1" if expired else "0")


def probe_mode(path):
    exists = "yes" if path.is_file() else "no"
    has_key = "false"
    expires_at = ""
    seconds_left = ""
    status = "EXPIRED"
    exit_code = 2

    if path.is_file():
        data = load_data(path)
        entry = pick_entry(data) if data is not None else None
        if entry and entry.get("key"):
            has_key = "true"
            raw = entry.get("expires_at") or entry.get("expiresAt")
            dt = parse_expires(raw)
            if dt is None:
                status = "ok"
                exit_code = 0
            else:
                if isinstance(raw, str):
                    expires_at = raw
                else:
                    expires_at = dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")
                now = datetime.datetime.now(datetime.timezone.utc)
                seconds_left = str(int((dt - now).total_seconds()))
                left = int(seconds_left)
                if left < 0:
                    status = "EXPIRED"
                    exit_code = 2
                elif left < SOON_SECONDS:
                    status = "soon"
                    exit_code = 1
                else:
                    status = "ok"
                    exit_code = 0

    print(
        "exists=%s has_key=%s expires_at=%s seconds_left=%s status=%s"
        % (exists, has_key, expires_at, seconds_left, status)
    )
    raise SystemExit(exit_code)


def main(argv):
    if len(argv) >= 2 and argv[1] == "--probe":
        target = Path(argv[2]) if len(argv) > 2 else Path("")
        probe_mode(target)
        return
    if len(argv) < 2:
        print("0")
        return
    default_mode(Path(argv[1]))


if __name__ == "__main__":
    main(sys.argv)
