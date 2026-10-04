// Tells Herdr when Pi is waiting on you.
//
// Pi fires ui_prompt_start and ui_prompt_end around every dialog an extension
// opens: a question tool's choices, a confirmation, an input box. Herdr's Pi
// integration marks the pane blocked only on its own `herdr:blocked` event,
// so without this a Pi agent asking a question still reads as working, and
// nothing that watches Herdr can tell it needs an answer.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  let waiting = false;

  pi.on("ui_prompt_start", (event) => {
    if (waiting) return;
    waiting = true;
    pi.events.emit("herdr:blocked", { active: true, label: event.title });
  });

  pi.on("ui_prompt_end", () => {
    if (!waiting) return;
    waiting = false;
    pi.events.emit("herdr:blocked", { active: false });
  });
}
