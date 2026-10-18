# No way out once a known self-host server is gone for good

**Where:** `src/Main.elm` — `GotHealth`, `ServerUnreachable` view

Once `clerk.server` is set, the app shows "Can't reach the Clerk server" forever unless the key is cleared by hand.

**Fix:** offer "Use this browser's storage instead" that clears `clerk.server` and switches to Disconnected.
