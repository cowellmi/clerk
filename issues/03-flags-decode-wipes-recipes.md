# One bad stored value resets all flags, and the next save wipes recipes

**Where:** `src/Main.elm` — `init` (~220), `flagsDecoder` (~2034)

`init.js` loads recipes separately to avoid this, but `flagsDecoder` decodes everything at once. If `clerk.recipes` is valid JSON but not an array, the whole decode fails, `recipes = []`, and the next Disconnected save overwrites stored recipes.

**Fix:** make each field fall back independently (`D.oneOf [ ..., D.succeed default ]`), like `Settings.formDecoder`.
