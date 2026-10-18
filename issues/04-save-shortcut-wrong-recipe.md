# Cmd/Ctrl+S on one recipe page saves another recipe's edit

**Where:** `src/Main.elm` — `SaveShortcut` (~469), `SaveEdit` (~527)

`recipeEdit` survives navigation. Edit A, open B, press Cmd+S: A's draft is saved silently.

**Fix:** in `SaveShortcut`, only send `SaveEdit` when the route's id equals `edit.id`.
