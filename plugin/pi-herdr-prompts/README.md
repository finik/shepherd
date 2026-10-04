# Pi prompts to Herdr

Makes a Pi agent report "blocked" to Herdr while it is waiting on you.

Pi's Herdr integration reports working and idle, and blocked only when an
extension says so on its own event. A question from a tool — Pi's example
`question.ts`, or any extension that opens a dialog — leaves the pane marked
working, so Herdr, Shepherd and its notifications cannot tell an answer is
needed. Pi fires `ui_prompt_start` and `ui_prompt_end` around every such
dialog; this extension passes them on as `herdr:blocked`.

## Install

```
cp herdr-prompt-blocked.ts ~/.pi/agent/extensions/
```

Pi loads it on its next start, or `/reload` in a running agent. It does
nothing outside Herdr: the integration it talks to only acts inside a pane.
