# Edits to the non-selected provider's settings aren't saved

**Where:** `src/Main.elm` — `settingsToSave` (~643)

Save is enabled only when the *parsed* settings change. Switch to Ollama, type a URL, switch back to DeepSeek: Save stays disabled and the URL is lost on reload, contradicting `src/Settings.elm:80-82`.

**Fix:** also enable Save when the form differs from the last saved form (keep a saved form alongside `saved`).
