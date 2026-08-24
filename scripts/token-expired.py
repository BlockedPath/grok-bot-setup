#!/usr/bin/env python3
import datetime, json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    print("0")
    raise SystemExit(0)
now = datetime.datetime.now(datetime.timezone.utc)
expired = False
entries = data.values() if isinstance(data, dict) else []
for entry in entries:
    if not isinstance(entry, dict):
        continue
    exp = entry.get("expires_at") or entry.get("expiresAt")
    if exp is None:
        continue
    try:
        if isinstance(exp, (int, float)):
            ts = float(exp)
            if ts > 1e12:
                ts /= 1000.0
            dt = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
        else:
            dt = datetime.datetime.fromisoformat(str(exp).replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
        if dt < now:
            expired = True
            break
    except Exception:
        continue
print("1" if expired else "0")
