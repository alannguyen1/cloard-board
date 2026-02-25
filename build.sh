#!/bin/sh
set -e
OUT="cloard-board"
: > "$OUT"
first=true
for f in src/*.sh; do
  if $first; then
    cat "$f" >> "$OUT"
    first=false
  else
    # Strip shebang from non-first files, keep everything else
    sed '1{/^#!/d;}' "$f" >> "$OUT"
  fi
done
chmod +x "$OUT"
echo "Built: $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
