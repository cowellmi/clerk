# No timeout or cancel for generation

**Where:** `src/Llm.elm` (~58)

`timeout = Nothing` and no Cancel button: a stalled provider leaves the chat box disabled until reload.

**Fix:** a timeout of a couple of minutes, or a Cancel button using `Http.cancel` with a tracker.
