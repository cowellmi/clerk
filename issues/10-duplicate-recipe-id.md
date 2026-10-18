# Same title saved twice in one second gives the same id

**Where:** `src/SavedRecipe.elm` — `new`

Server answers 409; in localStorage you get a duplicate id, and `WriteDelete` (filter by id) deletes both. Unlikely in practice.

**Fix:** add a short random suffix (server `idPattern` already allows extra `-[a-z0-9]+` segments).
