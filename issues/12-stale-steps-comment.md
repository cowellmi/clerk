# Stale comment on step textarea rows

**Where:** `src/Main.elm` (~1669)

Comment says steps "start at three lines", code uses `rows 5`. `public/style.css:554` notes `field-sizing` ignores `rows` anyway.

**Fix:** update the comment.
