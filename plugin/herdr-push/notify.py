#!/usr/bin/env python3
"""Send a notification when an agent stops.

Run by Herdr as a `pane.agent_status_changed` event hook, so there is no
polling and no daemon: the hook fires the moment the state changes, decides
whether the change is worth saying, and posts it.

Configuration lives in the plugin's config directory as `config.json`:

    {"url": "https://ntfy.sh/<topic>"}

Without it the hook does nothing, which is the right behaviour for a plugin
that is linked but not set up.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 10
OPENCODE_DB = "~/.local/share/opencode/opencode.db"


def main() -> int:
    event = json.loads(os.environ.get("HERDR_PLUGIN_EVENT_JSON") or "{}")
    # The envelope carries the event name; the fields are in `data`.
    data = event.get("data") if isinstance(event.get("data"), dict) else event
    pane_id = data.get("pane_id") or os.environ.get("HERDR_PANE_ID")
    status = data.get("agent_status")
    if not pane_id or not status:
        return 0

    # Herdr reports the new state; whether it is news depends on the old one,
    # so the hook keeps the last state it saw per pane.
    state_dir = os.environ.get("HERDR_PLUGIN_STATE_DIR") or "."
    os.makedirs(state_dir, exist_ok=True)
    state_path = os.path.join(state_dir, "last-status.json")
    seen = read_json(state_path)
    before = seen.get(pane_id)

    body = worth_saying(before, status)
    # Herdr keeps stderr per run, so say what was decided: a notification that
    # never arrived can then be traced to the transition behind it.
    print(f"{pane_id}: {before} -> {status} = {body or 'nothing to say'}",
          file=sys.stderr)
    if body is None:
        return 0

    # A question waits indefinitely and produces no further event, so
    # suppressing it means nobody is ever told. Only "finished" is worth
    # staying quiet about.
    suppressible = status != "blocked"

    config_dir = os.environ.get("HERDR_PLUGIN_CONFIG_DIR") or "."
    config = read_json(os.path.join(config_dir, "config.json"))

    # No point telling you about an agent you are sitting in front of. The
    # phone writes the threshold here, so the setting travels with the app.
    minutes = suppress_minutes(config, config_dir)
    if minutes > 0 and suppressible:
        herdr = os.environ.get("HERDR_BIN_PATH") or "herdr"
        since = since_last_interaction(herdr)
        if since is not None and since < minutes * 60:
            print(f"suppressed: you were here {int(since)}s ago",
                  file=sys.stderr)
            # Deliberately not recorded: leaving `before` where it was means
            # the next event still reads as news rather than as already told.
            return 0
    remember(state_path, pane_id, status)

    title = pane_title(pane_id)
    key_path = config.get("service_account")
    if key_path:
        send_fcm(key_path, config, title, body, pane_id)
    elif config.get("url"):
        send_ntfy(config["url"], title, body)
    else:
        print("nothing configured; nothing sent", file=sys.stderr)
    return 0


def suppress_minutes(config: dict, config_dir: str) -> int:
    """How recent counts as "still at the computer", in minutes; 0 disables."""
    try:
        with open(os.path.join(config_dir, "suppress-minutes")) as handle:
            return int(handle.read().strip())
    except Exception:
        pass
    try:
        return int(config.get("suppress_active_minutes") or 0)
    except (TypeError, ValueError):
        return 0


def since_last_interaction(herdr: str):
    """Seconds since you last did something, measured from Herdr's own data.

    Two sources, whichever is more recent: the newest user message in any
    agent's transcript — you prompting an agent on this machine — and the
    newest heartbeat under ~/.shepherd/active, which the phone touches while
    you are using it. Reading the news in a browser is not interaction; this
    deliberately does not look at system input.

    Returns None when nothing can be measured, which means "send anyway".
    """
    newest = None
    for stamp in (last_prompt_time(herdr), last_phone_time()):
        if stamp is not None and (newest is None or stamp > newest):
            newest = stamp
    if newest is None:
        return None
    since = time.time() - newest
    # A stamp from the future means the clock or the parse is wrong, not that
    # you are here. Unmeasurable sends; a clamped zero would silence.
    return None if since < -60 else max(0.0, since)


def last_prompt_time(herdr: str):
    """When a user message was last written to any agent's transcript."""
    newest = opencode_prompt_time(herdr)
    for path in transcript_paths(herdr):
        stamp = last_typed(path)
        if stamp is not None and (newest is None or stamp > newest):
            newest = stamp
    return newest


def last_typed(path: str):
    """The newest prompt you typed into one transcript, as epoch seconds.

    Read backwards a block at a time: one long agent turn puts megabytes of
    tool output after the prompt that started it.
    """
    try:
        handle = open(path, "rb")
    except OSError:
        return None
    with handle:
        end = handle.seek(0, os.SEEK_END)
        tail = b""
        while end > 0 and len(tail) < 16 << 20:
            start = max(0, end - (256 << 10))
            handle.seek(start)
            tail = handle.read(end - start) + tail
            end = start
            lines = tail.split(b"\n")
            # The first line may be cut off unless this is the file's start.
            for line in reversed(lines if start == 0 else lines[1:]):
                if b'"user"' not in line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if typed_by_you(record):
                    return parse_time(record.get("timestamp"))
    return None


def typed_by_you(record) -> bool:
    """Is this record something a person typed, in any agent's format?"""
    message = record.get("message")
    if isinstance(message, dict) and message.get("role") == "user":
        # Tool results are recorded as user messages; they are the agent
        # talking to itself, not you.
        content = message.get("content")
        if isinstance(content, list):
            return any(isinstance(b, dict) and b.get("type") == "text"
                       for b in content)
        return isinstance(content, str) and bool(content.strip())
    # Codex nests the conversation in response_item payloads, and opens every
    # session with user-role messages that are really the harness: an
    # environment block and instructions, each wrapped in a tag.
    payload = record.get("payload")
    if (record.get("type") == "response_item" and isinstance(payload, dict)
            and payload.get("type") == "message"
            and payload.get("role") == "user"):
        texts = [b.get("text", "") for b in payload.get("content") or []
                 if isinstance(b, dict) and b.get("type") == "input_text"]
        text = " ".join(texts).strip()
        return bool(text) and not text.startswith("<")
    return False


def last_phone_time():
    """The newest heartbeat the app left while you were using it."""
    directory = os.path.expanduser("~/.shepherd/active")
    newest = None
    try:
        names = os.listdir(directory)
    except OSError:
        return None
    for name in names:
        try:
            stamp = os.path.getmtime(os.path.join(directory, name))
        except OSError:
            continue
        if newest is None or stamp > newest:
            newest = stamp
    return newest


def transcript_paths(herdr: str):
    """Every agent transcript Herdr currently knows about."""
    snapshot = read_snapshot(herdr)
    paths = []
    for pane in snapshot.get("panes", []):
        session = pane.get("agent_session") or {}
        value = session.get("value") or ""
        if not value:
            # Herdr reports no session for Codex; its rollout is found by
            # the directory it was started in, as the app does.
            if pane.get("agent") == "codex" and pane.get("cwd"):
                found = codex_rollout(pane["cwd"])
                if found:
                    paths.append(found)
            continue
        if session.get("kind") == "path":
            paths.append(value)
        elif all(c.isalnum() or c in "._-" for c in value):
            paths.extend(find_by_id(value))
    return paths


def opencode_prompt_time(herdr: str):
    """When a message was last typed into an OpenCode session Herdr knows of.

    OpenCode keeps sessions in SQLite rather than in a transcript file.
    """
    ids = [(p.get("agent_session") or {}).get("value") or ""
           for p in read_snapshot(herdr).get("panes", [])
           if p.get("agent") == "opencode"]
    ids = [i for i in ids if i.startswith("ses_")]
    path = os.path.expanduser(OPENCODE_DB)
    if not ids or not os.path.exists(path):
        return None
    import sqlite3
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        marks = ",".join("?" * len(ids))
        row = db.execute(
            f"select max(time_created) from message where session_id in "
            f"({marks}) and json_extract(data, '$.role') = 'user'",
            ids).fetchone()
        db.close()
    except sqlite3.Error:
        return None
    return row[0] / 1000 if row and row[0] else None


def codex_rollout(cwd: str):
    """The newest Codex rollout started in this directory."""
    want = os.path.realpath(cwd)
    root = os.path.expanduser("~/.codex/sessions")
    best = None
    for base, _, names in os.walk(root):
        for name in names:
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            path = os.path.join(base, name)
            try:
                with open(path) as handle:
                    record = json.loads(handle.readline())
            except (OSError, ValueError):
                continue
            meta = record.get("payload") or {}
            if record.get("type") != "session_meta" or not meta.get("cwd"):
                continue
            if os.path.realpath(meta["cwd"]) != want:
                continue
            stamp = os.path.getmtime(path)
            if best is None or stamp > best[0]:
                best = (stamp, path)
    return best[1] if best else None


def find_by_id(session_id: str):
    try:
        out = subprocess.run(
            ["find", os.path.expanduser("~/.claude/projects"),
             os.path.expanduser("~/.codex/sessions"), "-maxdepth", "3",
             "-name", f"*{session_id}*.jsonl"],
            capture_output=True, text=True, timeout=TIMEOUT).stdout
    except Exception:
        return []
    return [line for line in out.splitlines() if line]


def parse_time(value):
    """A transcript timestamp as epoch seconds.

    A stamp with no offset is UTC — read as local time on a host west of
    Greenwich it lands hours in the future, and the clamp below would turn
    that into "you were here 0 seconds ago" and silence every notification
    until the clock caught up.
    """
    if not isinstance(value, str) or not value:
        return None
    try:
        import datetime
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=datetime.timezone.utc)
        return parsed.timestamp()
    except ValueError:
        return None


def remember(state_path: str, pane_id: str, status: str) -> None:
    """Record a status we acted on, atomically.

    One process per event means two panes changing at once are two processes
    reading and rewriting the same map; a temp-and-rename at least keeps the
    file valid, and losing one update costs a repeated notification rather
    than a corrupt map that makes every pane a first sighting again.
    """
    import tempfile

    seen = read_json(state_path)
    seen[pane_id] = status
    directory = os.path.dirname(state_path) or "."
    try:
        handle = tempfile.NamedTemporaryFile(
            "w", dir=directory, delete=False)
        with handle:
            json.dump(seen, handle)
        os.replace(handle.name, state_path)
    except Exception:
        pass


def worth_saying(before, now):
    """A first sighting is never news; finishing counts only if we saw it work.

    Blocked counts however it was reached, because nothing proceeds until the
    question is answered.
    """
    if before is None or before == now:
        return None
    if now == "blocked":
        return "Waiting for your answer"
    if before == "working" and now in ("done", "idle"):
        return "Finished"
    return None


_snapshot_cache = {}


def read_snapshot(herdr: str) -> dict:
    if "value" not in _snapshot_cache:
        try:
            out = subprocess.run([herdr, "api", "snapshot"],
                                 capture_output=True, text=True,
                                 timeout=TIMEOUT).stdout
            _snapshot_cache["value"] = json.loads(out)["result"]["snapshot"]
        except Exception:
            _snapshot_cache["value"] = {}
    return _snapshot_cache["value"]


def pane_title(pane_id: str) -> str:
    """What the phone should call this agent: its name, else its folder."""
    herdr = os.environ.get("HERDR_BIN_PATH") or "herdr"
    snapshot = read_snapshot(herdr)
    for pane in snapshot.get("panes", []):
        if pane.get("pane_id") != pane_id:
            continue
        label = (pane.get("label") or "").strip()
        if label:
            return label
        title = (pane.get("terminal_title_stripped") or "").strip()
        cwd = (pane.get("cwd") or "").rstrip("/").split("/")[-1]
        return title or cwd or pane_id
    return pane_id


def send_ntfy(url: str, title: str, body: str) -> None:
    body = f"{title}: {body}" if _header_safe(title) != title.strip() else body
    request = urllib.request.Request(
        url,
        data=body.encode(),
        # HTTP headers are latin-1, and a title is whatever the agent or the
        # folder is called: an emoji raises UnicodeEncodeError and a newline
        # is a header injection. ntfy reads the body as UTF-8, so the title
        # goes there when it will not survive the header.
        headers={"Title": _header_safe(title), "Tags": "robot"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        print(f"sent {title}: {body} ({response.status})")
    return


def _header_safe(value: str) -> str:
    """A header-safe version of a title, or a plain fallback."""
    flat = " ".join(value.split())
    try:
        flat.encode("latin-1")
    except UnicodeEncodeError:
        flat = flat.encode("ascii", "ignore").decode().strip()
    return flat or "Shepherd"


def send_fcm(key_path: str, config: dict, title: str, body: str,
             pane_id: str) -> None:
    """Send to every device that has registered a token.

    Tokens are files the app writes over its own SSH connection, one per
    device, so a new phone or a reinstall adds a file and a dead one is
    deleted when Google says it is gone.
    """
    key = read_json(os.path.expanduser(key_path))
    project = key.get("project_id")
    if not project:
        print(f"no project_id in {key_path}", file=sys.stderr)
        return
    token_dir = os.path.expanduser(
        config.get("token_dir") or "~/.shepherd/push-tokens")
    try:
        names = sorted(os.listdir(token_dir))
    except OSError:
        print(f"no tokens in {token_dir}", file=sys.stderr)
        return

    access = access_token(key)
    url = f"https://fcm.googleapis.com/v1/projects/{project}/messages:send"
    for name in names:
        path = os.path.join(token_dir, name)
        try:
            with open(path) as handle:
                device = handle.read().strip()
        except OSError:
            continue
        if not device:
            continue
        message = {
            "message": {
                "token": device,
                "notification": {"title": title, "body": body},
                "data": {"pane_id": pane_id},
                "android": {"priority": "HIGH"},
            }
        }
        request = urllib.request.Request(
            url,
            data=json.dumps(message).encode(),
            headers={
                "Authorization": f"Bearer {access}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                print(f"sent {title}: {body} to {name} ({response.status})")
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            # A token for an app that was uninstalled stays dead forever. The
            # code is in a details[] array at the end of the body, so the
            # whole body is searched.
            if error.code in (400, 403, 404) and "UNREGISTERED" in detail:
                try:
                    os.remove(path)
                except OSError:
                    pass
                print(f"dropped dead token {name}", file=sys.stderr)
            else:
                print(f"{name}: {error.code} {detail[:200]}", file=sys.stderr)


def access_token(key: dict) -> str:
    """Mint an OAuth2 access token from the service-account key.

    Signed here rather than with a library so the plugin needs nothing
    installed: a service account key is an RSA key and the assertion is three
    base64 segments.
    """
    import base64
    import time

    def segment(value: bytes) -> bytes:
        return base64.urlsafe_b64encode(value).rstrip(b"=")

    now = int(time.time())
    header = segment(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = segment(json.dumps({
        "iss": key["client_email"],
        "scope": "https://www.googleapis.com/auth/firebase.messaging",
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now,
        "exp": now + 3600,
    }).encode())
    signature = segment(sign_rs256(key["private_key"], header + b"." + claims))
    assertion = (header + b"." + claims + b"." + signature).decode()

    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }).encode()
    request = urllib.request.Request(
        "https://oauth2.googleapis.com/token", data=data, method="POST")
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.load(response)["access_token"]


def sign_rs256(private_key_pem: str, message: bytes) -> bytes:
    """RSA-SHA256 over the assertion, via openssl.

    The key goes to a file rather than down stdin: `openssl dgst -sign
    /dev/stdin` consumes the whole stream as the key and then signs what is
    left, which is nothing — it returns 0 and a valid-looking signature over
    an empty message, which Google rejects as invalid_grant.
    """
    import tempfile

    handle = tempfile.NamedTemporaryFile(delete=False)
    try:
        os.chmod(handle.name, 0o600)
        handle.write(private_key_pem.encode())
        handle.close()
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", handle.name, "-binary"],
            input=message, capture_output=True, timeout=TIMEOUT)
        if result.returncode != 0:
            raise RuntimeError(
                result.stderr.decode(errors="replace").strip() or "openssl failed")
        return result.stdout
    finally:
        os.unlink(handle.name)


def read_json(path: str) -> dict:
    try:
        with open(path) as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


if __name__ == "__main__":
    sys.exit(main())
