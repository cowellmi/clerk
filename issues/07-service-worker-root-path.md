# Service worker assumes the app is served at the root

**Where:** `public/init.js` (~145), `public/sw.js` (~17)

The app uses relative URLs to work under any mount (`src/Server.elm` header), but the SW registers `/sw.js` and only skips `/api/`. Under a subpath it either fails to register or caches `…/api/*` GETs, serving stale data offline.

**Fix:** register `sw.js` relatively; skip paths relative to the SW scope (`self.registration.scope + 'api/'`).
