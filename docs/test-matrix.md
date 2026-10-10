# Device test matrix

What to exercise on a real phone against a real Herdr host, and what each case
is actually testing. Ground truth for every case is the host: Herdr's snapshot
(`tool/ground_truth.sh <pane>`) and the agent's own transcript file. A case
passes only when the phone agrees with both.

Throwaway agents make this repeatable without touching real work:

```
herdr workspace create --cwd ~/shepherd-test/alpha --label test-claude --no-focus
herdr workspace create --cwd ~/shepherd-test/beta  --label test-pi     --no-focus
herdr workspace create --cwd ~/shepherd-test/gamma --label test-codex  --no-focus
herdr workspace create --cwd ~/shepherd-test/delta --label test-opencode --no-focus
herdr workspace create --cwd ~/shepherd-test/omega --label test-omp      --no-focus
herdr workspace create --cwd ~/shepherd-test/muse  --label test-muse     --no-focus
herdr pane run <pane> claude      # one of each, they parse differently
herdr pane run <pane> pi -e <pi>/examples/extensions/question.ts
herdr pane run <pane> codex
herdr pane run <pane> opencode
herdr pane run <pane> omp
herdr pane run <pane> muse --approval-mode untrusted --approval-judge off
```

Pi has no question tool of its own; the example extension gives it one. Pi
reports waiting to Herdr only with `plugin/pi-herdr-prompts` installed.

Screen coordinates for `adb shell input tap` are device pixels (1080×2410 on a
Pixel 10 Pro); screenshots are usually displayed scaled, so multiply the
coordinates read off a screenshot before tapping.

Case 13 needs an agent genuinely waiting on a prompt: Claude owns its own
lifecycle state, so a synthetic blocked state is overwritten within seconds and
proves nothing. Case 26 on an emulator forced into deep idle is milder than a
real device's Doze.

## Sessions list

| # | Case | Expected |
|---|------|----------|
| 1 | Agent blocked on a prompt | Hoisted into the accent field with the question verbatim, ANSWER and STOP |
| 2 | Agent working | Under WORKING with a spinner |
| 3 | Agent finished since last look | Under FINISHED SINCE YOU LOOKED with a tick |
| 4 | Preview text | Last thing the agent said, matching the transcript's last assistant record |
| 5 | Preview after the app was killed and restarted | Still matches; a scrape that raced the write must not stick |
| 6 | Pane renamed on the host | Row shows the label, not the terminal title |
| 7 | Terminal title rewritten by the agent | Row follows it, as Herdr does |

## Chat

| # | Case | Expected |
|---|------|----------|
| 8 | Claude agent, prompt with a tool call | User band, ledger line, reply; order matches the transcript |
| 9 | Pi agent, same | Same, and reasoning steps counted — Pi records them, Claude does not |
| 10 | Send from the phone | Message appears at once (SENDING until the transcript carries it) |
| 11 | Mid-turn | Activity strip names the current tool; stop control replaces send |
| 12 | Turn detail | Reasoning and calls in the order they happened; a call opens as a sheet |
| 13 | Agent blocked | The question is shown above the composer, not only in the list |
| 14 | Agent errored (expired token) | NO REPLY block with the reason, not an empty gap |
| 15 | Empty session (no transcript yet) | "Nothing written in this folder yet", never an endless spinner |
| 16 | Herdr points at a file that does not exist | Same, with the path named |

## Lifecycle

| # | Case | Expected |
|---|------|----------|
| 17 | Reply arrives while backgrounded | Present on return, once, in order |
| 18 | App killed mid-reply, relaunched | Reply present; no duplicate turns |
| 19 | Cold start, open a pane read before | Thread appears immediately from cache, then reconciles |
| 20 | Switch pane A → B → A | No content from one pane in the other; no duplicates |
| 21 | Tail process killed on the host | Recovers within ~15s at a higher offset |
| 22 | Tail alive but delivering nothing | Recovered by the size cross-check within ~30s |
| 23 | Host unreachable, then back | Reconnects; no silent staleness |

## Notifications

| # | Case | Expected |
|---|------|----------|
| 24 | Agent working → done while app is backgrounded | "Finished" within ~15s |
| 25 | Agent → blocked | "Waiting for your answer" |
| 26 | Screen off, device in deep Doze | Still delivered, late rather than lost |
| 27 | Settings while the watcher runs | Says what it is watching and when it last checked |
| 28 | Permission or battery exemption missing | Says which, in the accent |

## Updates

| # | Case | Expected |
|---|------|----------|
| 29 | Newer build published on the host | Offered in Settings and Machines |
| 30 | Download | Button fills left to right; percentage and megabytes both move |
| 31 | Download on a busy host | Slows rather than freezing; stalls fail after 30s |

## Long sessions

| # | Case | Expected |
|---|------|----------|
| 32 | Open a session hundreds of megabytes long | Last few turns within seconds; no ANR |
| 33 | Scroll past the top | Spinner, then the turns before it; repeat until the start |
| 34 | Agent writes pictures or megabytes of tool output | The chat keeps up; the host sends thumbnails and clipped output, not the bytes |

## Agents

| # | Case | Expected |
|---|------|----------|
| 35 | + on the sessions list | Agent and model pull-downs present at once, filled as the host answers; folders shown from `~/` |
| 36 | Start an agent with a model chosen | A new workspace in that folder, the agent on that model |
| 37 | Close an agent from the menu | Asks first; the pane closes on the host and leaves the list |
| 38 | Model line under the pie → another model | The agent moves to it; its saved default is unchanged on the host |
| 39 | Same → another effort only | The agent's effort changes; saved defaults unchanged |
| 40 | omp or OpenCode | The model line does not open a choice |

## Context, cost and subscriptions

| # | Case | Expected |
|---|------|----------|
| 41 | Context past 80% | Pie turns red |
| 42 | Tap the pie | Tokens used of the window, the cost, COMPACT and CLEAR; each asks first |
| 43 | Compact, then the next reply | Pie drops to what the agent now holds |
| 44 | Host with the herdr-agent-usage plugin or CodexBar | Two bars beside the pie for the agent's own plan, each with the time to reset; red from 80% |
| 45 | Tap the bars, or the cost | Subscriptions screen with every plan's limits, and why any could not be read |
| 46 | Host with neither | No bars; the cost is plain text |
| 47 | App backgrounded and reconnected | Bars stay up while they are read again |

## Web pages on the host

| # | Case | Expected |
|---|------|----------|
| 48 | Agent prints `http://localhost:<port>` for a server it started | The link opens the page in the app, interactive |
| 49 | Menu → Web pages on the host | Servers listed, the agent's folder first; a typed port opens too |
| 50 | Open in the browser from the page | Chrome shows the same page while Shepherd is connected |
| 51 | Port with nothing listening | Says nothing came back from that port, not a blank page |
| 52 | Put the page away, use the chat, pull the lip | The page comes back as it was, scroll and inputs intact |
| 53 | Back button with the page out | Back in the page first, then the page is put away, not closed |
