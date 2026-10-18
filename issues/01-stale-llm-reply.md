# Late reply from a discarded generation is taken as the next prompt's answer

**Where:** `src/Main.elm` — `GotReply` (~410), `forkRecipe` (~786)

Forking mid-generation sets `requestState = Idle`, and `GotReply` only drops replies while not awaiting. If you then send a new prompt before the old reply arrives, the old reply is accepted (replacing the forked recipe) and the real reply is later dropped.

**Fix:** give each request an incrementing id, carry it in `GotReply`, ignore mismatches.
