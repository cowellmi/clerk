# `tabindex 1` on Save

**Where:** `src/Main.elm` — `viewSaveButton` (~1920)

Puts Save ahead of the nav in tab order; positive tabindex is an accessibility anti-pattern.

**Fix:** drop it and rely on DOM order.
