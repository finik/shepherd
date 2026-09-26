#!/usr/bin/env python3
"""Checks for the notification hook. Run: python3 test_notify.py

No network, no real notification: the parts that decide *whether* to speak,
and the signing that decides whether anyone can hear it.
"""

import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import notify  # noqa: E402

failures = []


def check(name, condition):
    print(("  ok  " if condition else "FAIL  ") + name)
    if not condition:
        failures.append(name)


print("what is worth saying")
check("a first sighting is not news", notify.worth_saying(None, "done") is None)
check("finishing counts after working",
      notify.worth_saying("working", "done") == "Finished")
check("finishing without working does not",
      notify.worth_saying("idle", "done") is None)
check("blocked counts from anywhere",
      notify.worth_saying("idle", "blocked") == "Waiting for your answer")
check("no change is not news", notify.worth_saying("done", "done") is None)

print("\nthe assertion is signed over the assertion")
with tempfile.TemporaryDirectory() as tmp:
    key_path = os.path.join(tmp, "key.pem")
    subprocess.run(["openssl", "genrsa", "-out", key_path, "2048"],
                   capture_output=True, check=True)
    message = b"header.claims"
    signature = notify.sign_rs256(open(key_path).read(), message)
    # Checked against the public key, so a signature over the wrong bytes
    # fails here rather than at Google as invalid_grant.
    open(os.path.join(tmp, "msg"), "wb").write(message)
    open(os.path.join(tmp, "sig"), "wb").write(signature)
    subprocess.run(["openssl", "rsa", "-in", key_path, "-pubout",
                    "-out", os.path.join(tmp, "pub.pem")], capture_output=True)
    verify = subprocess.run(
        ["openssl", "dgst", "-sha256", "-verify", os.path.join(tmp, "pub.pem"),
         "-signature", os.path.join(tmp, "sig"), os.path.join(tmp, "msg")],
        capture_output=True, text=True)
    check("openssl verifies it", "Verified OK" in verify.stdout)

print("\nwhat counts as you being here")
with tempfile.TemporaryDirectory() as tmp:
    transcript = os.path.join(tmp, "session.jsonl")
    with open(transcript, "w") as handle:
        handle.write(json.dumps({
            "type": "user",
            "timestamp": "2026-01-01T00:00:00Z",
            "message": {"role": "user",
                        "content": [{"type": "text", "text": "hello"}]},
        }) + "\n")
        # A tool result is also recorded as a user message; it is the agent
        # talking to itself and must not count as you being at the keyboard.
        handle.write(json.dumps({
            "type": "user",
            "timestamp": "2030-01-01T00:00:00Z",
            "message": {"role": "user",
                        "content": [{"type": "tool_result", "content": "out"}]},
        }) + "\n")
    original = notify.transcript_paths
    notify.transcript_paths = lambda _herdr: [transcript]
    notify.OPENCODE_DB = os.path.join(tmp, "absent.db")
    try:
        newest = notify.last_prompt_time("herdr")
    finally:
        notify.transcript_paths = original
    import datetime
    expected = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
    check("a prompt is found", newest is not None)
    check("a tool result is not mistaken for you",
          newest is not None and abs(newest - expected.timestamp()) < 1)

print("\na prompt buried under a long turn is still found")
with tempfile.TemporaryDirectory() as tmp:
    transcript = os.path.join(tmp, "long.jsonl")
    with open(transcript, "w") as handle:
        handle.write(json.dumps({
            "type": "user", "timestamp": "2026-01-01T00:00:00Z",
            "message": {"role": "user", "content": "run the whole suite"},
        }) + "\n")
        for _ in range(400):
            handle.write(json.dumps({
                "type": "user", "timestamp": "2026-01-01T00:05:00Z",
                "message": {"role": "user", "content": [
                    {"type": "tool_result", "content": "x" * 4000}]},
            }) + "\n")
    import datetime
    check("found past 1.6MB of tool output",
          notify.last_typed(transcript) == datetime.datetime(
              2026, 1, 1, tzinfo=datetime.timezone.utc).timestamp())

print("\nwhat Claude writes on its own does not count")
check("a background task reporting back is not you", not notify.typed_by_you({
    "type": "user", "promptSource": "system",
    "origin": {"kind": "task-notification"},
    "message": {"role": "user", "content": "<task-notification>…"}}))
check("a typed prompt is", notify.typed_by_you({
    "type": "user", "promptSource": "typed", "origin": {"kind": "human"},
    "message": {"role": "user", "content": "check the history"}}))

print("\nwhat you typed into codex counts too")
check("a codex prompt is you", notify.typed_by_you({
    "type": "response_item", "payload": {
        "type": "message", "role": "user",
        "content": [{"type": "input_text", "text": "why is it slow"}]}}))
check("the harness preamble is not", not notify.typed_by_you({
    "type": "response_item", "payload": {
        "type": "message", "role": "user",
        "content": [{"type": "input_text",
                     "text": "<environment_context>x</environment_context>"}]}}))
check("a codex reply is not", not notify.typed_by_you({
    "type": "response_item", "payload": {
        "type": "message", "role": "assistant",
        "content": [{"type": "output_text", "text": "done"}]}}))

print("\nwhat you typed into opencode counts too")
with tempfile.TemporaryDirectory() as tmp:
    import sqlite3
    path = os.path.join(tmp, "opencode.db")
    db = sqlite3.connect(path)
    db.execute("create table message (id text, session_id text, "
               "time_created integer, data text)")
    db.executemany("insert into message values (?, ?, ?, ?)", [
        ("m1", "ses_a", 1_000_000, json.dumps({"role": "user"})),
        ("m2", "ses_a", 9_000_000, json.dumps({"role": "assistant"})),
        ("m3", "ses_b", 5_000_000, json.dumps({"role": "user"})),
    ])
    db.commit()
    db.close()
    notify.OPENCODE_DB = path
    notify._snapshot_cache["value"] = {"panes": [
        {"agent": "opencode", "agent_session": {"kind": "id", "value": "ses_a"}}]}
    check("the newest message you typed in that session",
          notify.opencode_prompt_time("herdr") == 1000)
    notify._snapshot_cache.clear()

print("\nstate is recorded atomically")
with tempfile.TemporaryDirectory() as tmp:
    state = os.path.join(tmp, "last-status.json")
    notify.remember(state, "w1:p1", "working")
    notify.remember(state, "w1:p2", "blocked")
    stored = notify.read_json(state)
    check("both panes kept", stored == {"w1:p1": "working", "w1:p2": "blocked"})
    check("no temp files left", os.listdir(tmp) == ["last-status.json"])

print()
if failures:
    print(f"{len(failures)} failed: " + ", ".join(failures))
    sys.exit(1)
print("all checks passed")
