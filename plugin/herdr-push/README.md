# Shepherd push

Notifies your phone when an agent stops, without the app running.

Shepherd's in-app watcher holds an SSH connection open and polls every ten
seconds, which only works while the app is alive and Android lets it talk.
This plugin covers the rest: Herdr knows the instant an agent's
state changes, so a `pane.agent_status_changed` event hook sends the
notification from the host. No daemon, no polling, nothing to supervise —
Herdr runs the hook and logs its exit code, stdout and stderr.

## Setup

```
herdr plugin link /path/to/shepherd/plugin/herdr-push
```

Then write `config.json` into the plugin's config directory
(`herdr plugin config-dir shepherd.push` prints it). Two destinations are
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

Without the config file the hook exits quietly, which is what a linked but
unconfigured plugin should do.

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

```
herdr plugin log --plugin shepherd.push --limit 30
```

Each run logs the decision it made, so a notification that did not arrive can
be traced to the transition that did or did not justify it.
