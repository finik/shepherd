# Shepherd push

Notifies your phone when an agent stops, without the app running.

Shepherd's in-app watcher holds an SSH connection open and polls every ten
seconds, which only works while the app is alive and Android lets it talk.
This covers the rest: the host knows the instant an agent's state changes,
and sends the notification itself.

## Setup

**With the Herdr app (herdr-core)**, run `notify.py --core` and keep it
running. It follows `hc events` and decides on each change of state. On
macOS, a LaunchAgent at `~/Library/LaunchAgents/com.shepherd.push.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.shepherd.push</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string><string>python3</string>
    <string>/path/to/shepherd/plugin/herdr-push/notify.py</string><string>--core</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/Users/you/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/Users/you/.local/state/herdr/plugins/shepherd.push/core.log</string>
</dict>
</plist>
```

then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.shepherd.push.plist`.
On Linux, a systemd user unit:

```ini
# ~/.config/systemd/user/shepherd-push.service
[Service]
ExecStart=/usr/bin/python3 /path/to/shepherd/plugin/herdr-push/notify.py --core
Environment=PATH=%h/.local/bin:/usr/bin:/bin
Restart=always

[Install]
WantedBy=default.target
```

then `systemctl --user enable --now shepherd-push`.

**With Herdr TUI**, link it as a plugin; Herdr runs it on
`pane.agent_status_changed` and logs each run:

```
herdr plugin link /path/to/shepherd/plugin/herdr-push
```

Either way, write `config.json` into
`~/.config/herdr/plugins/config/shepherd.push/` (with Herdr TUI,
`herdr plugin config-dir shepherd.push` prints it). Two destinations are
supported.

**Firebase Cloud Messaging**, straight to the Shepherd app:

```
{"service_account": "/path/to/service-account.json"}
```

The key is a Firebase service-account JSON for the project the app was built
against. The app registers each phone by writing its token under
`~/.shepherd/push-tokens/` over its own SSH connection; `token_dir` overrides
that path. A token Google reports as unregistered is deleted.

**ntfy**, to the ntfy app:

```
{"url": "https://ntfy.sh/<a topic name nobody will guess>"}
```

Anyone who knows a public ntfy topic can read it, so make the name long and
random, or point the URL at your own ntfy server.

Without the config file nothing is sent.

## What it sends

- `working → done` or `working → idle` — "Finished"
- anything → `blocked` — "Waiting for your answer"

A first sighting is never news: an agent that was already finished when the
hook first saw it did not just finish. The title is the pane's label if you
renamed it, else its terminal title, else the folder.

## Staying quiet while you are here

"Finished" is not sent if you were active in the last few minutes: a prompt
typed into any agent's transcript on the host, or a heartbeat the app leaves
under `~/.shepherd/active` while it is open. The app writes the window to
`suppress-minutes` in the config directory; `suppress_active_minutes` in
`config.json` is the fallback. "Waiting for your answer" is always sent.

## Checking on it

With herdr-core, the decisions go to `core.log` (as set in the LaunchAgent
or unit above). With Herdr TUI:

```
herdr plugin log --plugin shepherd.push --limit 30
```

Each decision is logged the decision it made, so a notification that did not arrive can
be traced to the transition that did or did not justify it.
