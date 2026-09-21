"""
helpdesk-agent server
Command-and-control portal for Windows endpoint agents.

Agent flow:
  1. POST /api/agent/register  (AGENT_SECRET + device info)  -> {device_id, token}
  2. GET  /api/agent/poll      ?device_id=X&token=Y every 30s -> {command} or null
  3. POST /api/agent/result    {device_id, token, command_id, result, exit_code, error}

Admin flow:
  1. Create command in UI     -> status: pending_confirm
  2. Confirm in UI            -> status: queued
  3. Agent picks up on poll   -> status: running
  4. Agent posts result       -> status: done | failed | timeout | cancelled

All admin actions are audit-logged to /data/audit.log (JSON lines).
ASCII-only comments (SunPassion convention).
"""

import asyncio
import base64
import json
import os
import secrets
import sqlite3
import threading
import time
from datetime import datetime, timezone

from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

# ------------------------------------------------------------------ config

DATA_DIR       = os.environ.get("DATA_DIR", "/data")
os.makedirs(DATA_DIR, exist_ok=True)

DB_PATH        = os.path.join(DATA_DIR, "helpdesk.db")
AUDIT_PATH     = os.path.join(DATA_DIR, "audit.log")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
AGENT_SECRET   = os.environ.get("AGENT_SECRET", "")   # pre-shared key for registration

SESSION_TTL    = 12 * 3600
SESSIONS: dict = {}   # sid -> {ts: float}

# Per-type timeout in seconds (watchdog marks command 'timeout' after this + 60s margin)
CMD_TIMEOUT = {
    "sysinfo":  60,   "netinfo":   60,  "eventlog": 90,
    "defender": 60,   "updates":  120,  "printers": 30,
    "processes": 30,  "wifi":      30,  "gpresult": 120,
    "ping":     30,   "shell":    300,
    "listdir":  30,   "readfile":  30,  "getfile":  120,
}

CMD_LABELS = {
    "sysinfo":   "System Info",    "netinfo":   "Network Info",
    "eventlog":  "Event Log",      "defender":  "Defender",
    "updates":   "Windows Update", "printers":  "Printers",
    "processes": "Processes",      "wifi":      "Wi-Fi",
    "gpresult":  "Group Policy",   "ping":      "Ping",
    "shell":     "PowerShell",
    "listdir":   "List Directory", "readfile":  "Read File",
    "getfile":   "Download File",
}

# Command types that return file content (audit records the target path).
FILE_CMDS = {"listdir", "readfile", "getfile"}

_db_lock = threading.Lock()

# ------------------------------------------------------------------ db

def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.row_factory = sqlite3.Row
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS devices (
            device_id     TEXT PRIMARY KEY,
            token         TEXT NOT NULL,
            hostname      TEXT,
            os_version    TEXT,
            username      TEXT,
            domain        TEXT,
            machine_guid  TEXT,
            agent_version TEXT,
            first_seen    TEXT NOT NULL,
            last_seen     TEXT,
            last_ip       TEXT
        );
        CREATE TABLE IF NOT EXISTS commands (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id    TEXT    NOT NULL,
            cmd_type     TEXT    NOT NULL,
            payload      TEXT    DEFAULT '{}',
            status       TEXT    NOT NULL DEFAULT 'pending_confirm',
            created_at   TEXT    NOT NULL,
            confirmed_at TEXT,
            picked_at    TEXT,
            completed_at TEXT,
            result       TEXT,
            exit_code    INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_cmd_device ON commands(device_id);
        CREATE INDEX IF NOT EXISTS idx_cmd_status  ON commands(status);
        CREATE TABLE IF NOT EXISTS inventory (
            device_id  TEXT NOT NULL,
            kind       TEXT NOT NULL,
            data       TEXT,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (device_id, kind)
        );
    """)
    conn.commit()
    return conn

# ------------------------------------------------------------------ audit

def audit(action: str, detail: dict, user: str = "admin"):
    entry = {"ts": datetime.now(timezone.utc).isoformat(),
             "user": user, "action": action, "detail": detail}
    with open(AUDIT_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

# ------------------------------------------------------------------ auth

def require_auth(req: Request):
    if not ADMIN_PASSWORD:
        return "open"
    sid  = req.cookies.get("sid", "")
    sess = SESSIONS.get(sid)
    if not sess or time.time() - sess["ts"] > SESSION_TTL:
        raise HTTPException(401, "login required")
    sess["ts"] = time.time()
    return sid

# ------------------------------------------------------------------ app

app = FastAPI(title="helpdesk-agent")

# ---- auth endpoints ----

@app.post("/api/login")
async def login(request: Request, response: Response):
    body = await request.json()
    if not ADMIN_PASSWORD:
        return {"ok": True, "open": True}
    if body.get("password") != ADMIN_PASSWORD:
        raise HTTPException(403, "wrong password")
    sid = secrets.token_urlsafe(32)
    SESSIONS[sid] = {"ts": time.time()}
    response.set_cookie("sid", sid, httponly=True, samesite="lax")
    audit("admin.login", {})
    return {"ok": True}

@app.post("/api/logout")
async def logout(request: Request, response: Response):
    SESSIONS.pop(request.cookies.get("sid", ""), None)
    response.delete_cookie("sid")
    return {"ok": True}

@app.get("/api/whoami")
async def whoami(request: Request):
    try:
        require_auth(request)
        return {"authed": True, "open_mode": not ADMIN_PASSWORD}
    except HTTPException:
        return {"authed": False, "open_mode": not ADMIN_PASSWORD}

# ================================================================ agent API

@app.post("/api/agent/register")
async def agent_register(request: Request):
    """Called by agent on first install or when token is lost."""
    body = await request.json()
    if AGENT_SECRET and body.get("secret") != AGENT_SECRET:
        raise HTTPException(403, "bad secret")

    machine_guid = body.get("machine_guid", "")
    hostname     = body.get("hostname", "UNKNOWN")
    device_id    = machine_guid or hostname
    now          = datetime.now(timezone.utc).isoformat()
    client_ip    = request.client.host if request.client else ""

    with _db_lock:
        conn = db()
        row  = conn.execute(
            "SELECT token, first_seen FROM devices WHERE device_id=?", (device_id,)
        ).fetchone()
        # Keep existing token on re-registration (device must not lose its token)
        token      = row["token"]      if row else secrets.token_urlsafe(32)
        first_seen = row["first_seen"] if row else now

        conn.execute("""
            INSERT INTO devices
                (device_id, token, hostname, os_version, username, domain,
                 machine_guid, agent_version, first_seen, last_seen, last_ip)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(device_id) DO UPDATE SET
                hostname=excluded.hostname,
                os_version=excluded.os_version,
                username=excluded.username,
                domain=excluded.domain,
                agent_version=excluded.agent_version,
                last_seen=excluded.last_seen,
                last_ip=excluded.last_ip
        """, (device_id, token, hostname,
              body.get("os_version", ""), body.get("username", ""),
              body.get("domain", ""), machine_guid,
              body.get("agent_version", "1.0"),
              first_seen, now, client_ip))
        conn.commit()
        conn.close()

    audit("agent.register",
          {"device_id": device_id, "hostname": hostname, "ip": client_ip},
          user="agent")
    return {"device_id": device_id, "token": token}


def _claim_next_command(device_id: str, token: str, client_ip: str):
    """Verify token, heartbeat, and atomically claim the oldest queued command.
    Returns (cmd_dict_or_None, bad_token_bool)."""
    now = datetime.now(timezone.utc).isoformat()
    with _db_lock:
        conn = db()
        dev = conn.execute(
            "SELECT token FROM devices WHERE device_id=?", (device_id,)
        ).fetchone()
        if not dev or dev["token"] != token:
            conn.close()
            return None, True
        conn.execute(
            "UPDATE devices SET last_seen=?, last_ip=? WHERE device_id=?",
            (now, client_ip, device_id)
        )
        cmd = conn.execute("""
            SELECT id, cmd_type, payload FROM commands
            WHERE device_id=? AND status='queued'
            ORDER BY id ASC LIMIT 1
        """, (device_id,)).fetchone()
        if cmd:
            conn.execute(
                "UPDATE commands SET status='running', picked_at=? WHERE id=?",
                (now, cmd["id"])
            )
        conn.commit()
        result = None
        if cmd:
            result = {
                "id":      cmd["id"],
                "type":    cmd["cmd_type"],
                "payload": json.loads(cmd["payload"] or "{}"),
                "timeout": CMD_TIMEOUT.get(cmd["cmd_type"], 60),
            }
        conn.close()
        return result, False


# How long the server holds a poll open waiting for a command (long-poll).
# Makes interactive browsing/shell feel near-instant instead of waiting a full
# poll interval. Kept short enough to be scalable across the fleet.
LONGPOLL_SECONDS = 20


@app.get("/api/agent/poll")
async def agent_poll(request: Request, device_id: str = "", token: str = ""):
    """Long-poll: returns immediately if a command is queued, otherwise holds
    the connection up to LONGPOLL_SECONDS, checking once a second."""
    if not device_id or not token:
        raise HTTPException(400, "device_id and token required")

    client_ip = request.client.host if request.client else ""
    deadline = time.time() + LONGPOLL_SECONDS
    first = True
    while True:
        cmd, bad = _claim_next_command(device_id, token, client_ip)
        if bad:
            raise HTTPException(403, "bad token")
        if cmd:
            return {"command": cmd}
        if time.time() >= deadline:
            return {"command": None}
        # Heartbeat only needs to happen once; then just wait.
        first = False
        await asyncio.sleep(1)


@app.post("/api/agent/result")
async def agent_result(request: Request):
    """Agent posts command result here."""
    body      = await request.json()
    device_id = body.get("device_id", "")
    token     = body.get("token", "")
    cmd_id    = int(body.get("command_id", 0))

    with _db_lock:
        conn = db()
        dev = conn.execute(
            "SELECT token FROM devices WHERE device_id=?", (device_id,)
        ).fetchone()
        if not dev or dev["token"] != token:
            conn.close()
            raise HTTPException(403, "bad token")

        status = "failed" if body.get("error") else "done"
        conn.execute("""
            UPDATE commands
            SET status=?, result=?, exit_code=?, completed_at=?
            WHERE id=? AND device_id=?
        """, (status, body.get("result", ""), body.get("exit_code", 0),
              datetime.now(timezone.utc).isoformat(), cmd_id, device_id))
        conn.commit()
        conn.close()

    return {"ok": True}


@app.post("/api/agent/inventory")
async def agent_inventory(request: Request):
    """Agent pushes an inventory snapshot (auto-report). Body:
    {device_id, token, items: {kind: <json string>, ...}}. Upsert per kind."""
    body      = await request.json()
    device_id = body.get("device_id", "")
    token     = body.get("token", "")
    items     = body.get("items", {}) or {}

    now = datetime.now(timezone.utc).isoformat()
    with _db_lock:
        conn = db()
        dev = conn.execute(
            "SELECT token FROM devices WHERE device_id=?", (device_id,)
        ).fetchone()
        if not dev or dev["token"] != token:
            conn.close()
            raise HTTPException(403, "bad token")
        conn.execute(
            "UPDATE devices SET last_seen=?, last_ip=? WHERE device_id=?",
            (now, request.client.host if request.client else "", device_id)
        )
        for kind, data in items.items():
            if not isinstance(data, str):
                data = json.dumps(data, ensure_ascii=False)
            conn.execute("""
                INSERT INTO inventory (device_id, kind, data, updated_at)
                VALUES (?,?,?,?)
                ON CONFLICT(device_id, kind) DO UPDATE SET
                    data=excluded.data, updated_at=excluded.updated_at
            """, (device_id, kind, data, now))
        conn.commit()
        conn.close()
    return {"ok": True, "stored": list(items.keys())}

# ============================================================== admin API

@app.get("/api/devices/{device_id}/inventory")
async def get_device_inventory(request: Request, device_id: str):
    """Latest auto-reported inventory snapshots for the dashboard."""
    require_auth(request)
    conn = db()
    rows = conn.execute(
        "SELECT kind, data, updated_at FROM inventory WHERE device_id=?",
        (device_id,)
    ).fetchall()
    conn.close()
    inv = {}
    for r in rows:
        try:
            parsed = json.loads(r["data"]) if r["data"] else None
        except Exception:
            parsed = r["data"]
        inv[r["kind"]] = {"data": parsed, "updated_at": r["updated_at"]}
    return {"inventory": inv}


async def get_devices(request: Request):
    require_auth(request)
    conn = db()
    rows = [dict(r) for r in conn.execute("""
        SELECT d.device_id, d.hostname, d.os_version, d.username, d.domain,
               d.last_seen, d.last_ip, d.agent_version,
               (SELECT COUNT(*) FROM commands
                WHERE device_id=d.device_id
                  AND status IN ('pending_confirm','queued','running')) AS pending_count
        FROM devices d
        ORDER BY d.last_seen DESC
    """)]
    conn.close()
    return {"devices": rows}


@app.get("/api/devices/{device_id}/commands")
async def get_device_commands(request: Request, device_id: str, limit: int = 100):
    require_auth(request)
    conn = db()
    rows = [dict(r) for r in conn.execute("""
        SELECT id, cmd_type, payload, status,
               created_at, confirmed_at, picked_at, completed_at,
               exit_code,
               CASE WHEN length(result) > 500
                    THEN substr(result,1,500)||'...[truncated]'
                    ELSE result END AS result_preview
        FROM commands WHERE device_id=?
        ORDER BY id DESC LIMIT ?
    """, (device_id, limit))]
    conn.close()
    return {"commands": rows, "cmd_labels": CMD_LABELS}


@app.get("/api/commands")
async def get_commands(request: Request, status: str = "", limit: int = 200):
    require_auth(request)
    q = """SELECT c.id, c.device_id, d.hostname, c.cmd_type, c.payload,
                  c.status, c.created_at, c.confirmed_at, c.picked_at,
                  c.completed_at, c.exit_code,
                  CASE WHEN length(c.result) > 300
                       THEN substr(c.result,1,300)||'...'
                       ELSE c.result END AS result_preview
           FROM commands c
           LEFT JOIN devices d ON c.device_id=d.device_id
           WHERE 1=1"""
    args: list = []
    if status:
        q += " AND c.status=?"
        args.append(status)
    q += " ORDER BY c.id DESC LIMIT ?"
    args.append(limit)
    conn = db()
    rows = [dict(r) for r in conn.execute(q, args)]
    conn.close()
    return {"commands": rows, "cmd_labels": CMD_LABELS}


@app.post("/api/commands")
async def create_command(request: Request):
    """Create a command. With confirm=true it goes straight to 'queued' (used by
    the live dashboard); otherwise it waits in 'pending_confirm'. Either way it
    is audit-logged, and getfile is still gated by the agent's allowlist."""
    require_auth(request)
    body      = await request.json()
    device_id = body.get("device_id", "")
    cmd_type  = body.get("cmd_type", "")
    payload   = body.get("payload", {})
    immediate = bool(body.get("confirm", False))

    if not device_id or not cmd_type:
        raise HTTPException(400, "device_id and cmd_type required")
    if cmd_type not in CMD_TIMEOUT:
        raise HTTPException(400, f"unknown cmd_type: {cmd_type}")

    now = datetime.now(timezone.utc).isoformat()
    status = "queued" if immediate else "pending_confirm"
    with _db_lock:
        conn = db()
        cur = conn.execute("""
            INSERT INTO commands (device_id, cmd_type, payload, status, created_at, confirmed_at)
            VALUES (?,?,?,?,?,?)
        """, (device_id, cmd_type, json.dumps(payload), status, now,
              now if immediate else None))
        cmd_id = cur.lastrowid
        conn.commit()
        conn.close()

    audit("command.create", {
        "id": cmd_id, "device_id": device_id,
        "cmd_type": cmd_type, "payload": payload, "immediate": immediate,
    })
    return {"id": cmd_id, "status": status}


@app.post("/api/commands/{cmd_id}/confirm")
async def confirm_command(request: Request, cmd_id: int):
    """Confirm a pending_confirm command -> moves it to queued."""
    require_auth(request)
    with _db_lock:
        conn = db()
        cmd = conn.execute(
            "SELECT id, device_id, cmd_type, status FROM commands WHERE id=?",
            (cmd_id,)
        ).fetchone()
        if not cmd:
            conn.close()
            raise HTTPException(404)
        if cmd["status"] != "pending_confirm":
            conn.close()
            raise HTTPException(400, f"cannot confirm: status={cmd['status']}")
        conn.execute(
            "UPDATE commands SET status='queued', confirmed_at=? WHERE id=?",
            (datetime.now(timezone.utc).isoformat(), cmd_id)
        )
        conn.commit()
        conn.close()

    audit("command.confirm", {
        "id": cmd_id, "device_id": cmd["device_id"], "cmd_type": cmd["cmd_type"],
    })
    return {"ok": True}


@app.post("/api/commands/{cmd_id}/cancel")
async def cancel_command(request: Request, cmd_id: int):
    require_auth(request)
    with _db_lock:
        conn = db()
        cmd = conn.execute(
            "SELECT status FROM commands WHERE id=?", (cmd_id,)
        ).fetchone()
        if not cmd:
            conn.close()
            raise HTTPException(404)
        if cmd["status"] not in ("pending_confirm", "queued"):
            conn.close()
            raise HTTPException(400, f"cannot cancel: status={cmd['status']}")
        conn.execute("UPDATE commands SET status='cancelled' WHERE id=?", (cmd_id,))
        conn.commit()
        conn.close()

    audit("command.cancel", {"id": cmd_id})
    return {"ok": True}


@app.get("/api/commands/{cmd_id}/result")
async def get_result(request: Request, cmd_id: int):
    """Fetch full result text for a completed command."""
    require_auth(request)
    conn = db()
    cmd = conn.execute(
        "SELECT id, cmd_type, status, completed_at, result, exit_code "
        "FROM commands WHERE id=?",
        (cmd_id,)
    ).fetchone()
    conn.close()
    if not cmd:
        raise HTTPException(404)
    return dict(cmd)


@app.get("/api/commands/{cmd_id}/download")
async def download_file(request: Request, cmd_id: int):
    """Decode a completed getfile result and stream it back as a file.
    The download itself is audit-logged (who pulled which file off which host)."""
    require_auth(request)
    conn = db()
    cmd = conn.execute(
        "SELECT id, device_id, cmd_type, status, result FROM commands WHERE id=?",
        (cmd_id,)
    ).fetchone()
    conn.close()
    if not cmd:
        raise HTTPException(404)
    if cmd["cmd_type"] != "getfile":
        raise HTTPException(400, "not a getfile command")
    if cmd["status"] != "done":
        raise HTTPException(400, f"command not complete (status={cmd['status']})")

    try:
        meta = json.loads(cmd["result"] or "{}")
    except Exception:
        raise HTTPException(500, "result is not valid JSON")
    b64 = meta.get("b64", "")
    if not b64:
        # Agent refused (outside allowlist) or error -> surface the message
        raise HTTPException(400, meta.get("error") or "no file content in result")

    try:
        raw = base64.b64decode(b64)
    except Exception:
        raise HTTPException(500, "failed to decode file content")

    filename = os.path.basename(meta.get("path", "")) or f"file_{cmd_id}.bin"

    audit("file.download", {
        "id": cmd_id, "device_id": cmd["device_id"],
        "path": meta.get("path", ""), "size": meta.get("size", len(raw)),
        "sha256": meta.get("sha256", ""),
    })

    return Response(
        content=raw,
        media_type="application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@app.get("/api/audit")
async def get_audit(request: Request):
    require_auth(request)
    lines: list = []
    if os.path.exists(AUDIT_PATH):
        with open(AUDIT_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        lines.append(json.loads(line))
                    except Exception:
                        pass
    return {"entries": lines[-500:][::-1]}

# ---------------------------------------------------------------- watchdog

def _watchdog():
    """Mark 'running' commands as 'timeout' if they exceed their time limit."""
    while True:
        time.sleep(60)
        try:
            now = datetime.now(timezone.utc)
            with _db_lock:
                conn = db()
                running = [dict(r) for r in conn.execute(
                    "SELECT id, cmd_type, picked_at FROM commands WHERE status='running'"
                )]
                for cmd in running:
                    if not cmd["picked_at"]:
                        continue
                    timeout = CMD_TIMEOUT.get(cmd["cmd_type"], 60)
                    try:
                        picked = datetime.fromisoformat(
                            cmd["picked_at"].replace("Z", "+00:00")
                        )
                    except Exception:
                        continue
                    if (now - picked).total_seconds() > timeout + 60:
                        conn.execute(
                            "UPDATE commands SET status='timeout', completed_at=? "
                            "WHERE id=?",
                            (now.isoformat(), cmd["id"])
                        )
                conn.commit()
                conn.close()
        except Exception as e:
            print(f"[watchdog] {e}", flush=True)

@app.on_event("startup")
async def startup():
    db()  # ensure schema
    threading.Thread(target=_watchdog, daemon=True).start()

# ---------------------------------------------------------------- static

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
os.makedirs(STATIC_DIR, exist_ok=True)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

@app.get("/")
async def index():
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))
