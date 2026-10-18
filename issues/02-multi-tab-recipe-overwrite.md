# Two tabs in localStorage mode overwrite each other's saved recipes

**Where:** `src/Main.elm` — `startWrite`, `Disconnected` branch (~826); `public/init.js`

Each save writes the tab's whole in-memory `savedRecipes` to `clerk.recipes`. Nothing listens for `storage` events, so saving A in the installed app and B in a browser tab leaves only B.

**Fix:** listen for `storage` in `init.js` and push the new list into Elm via a port (or re-read before writing).
