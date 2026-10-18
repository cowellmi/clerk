# Self-host server accepts cross-site writes

**Where:** `server/server.go` — `readRecipe` (~146), `New`

No `Content-Type` check, so any page can `POST /api/recipes` as `text/plain` (no CORS preflight) to `localhost:8080`. Those recipes later reach the LLM if forked. No `Host` check, so DNS rebinding could read/delete data. Worse when bound beyond localhost.

**Fix:** require `application/json` on POST (forces preflight); reject unexpected `Host` values.
