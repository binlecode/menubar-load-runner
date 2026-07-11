#!/usr/bin/env bash
#
# build-cover-dist.sh — assemble + audit the Cloudflare Pages deploy bundle for docs/cover.html.
#
# Produces a throwaway tmp/cover-dist/ (page -> index.html, only the GIFs the cover references beside
# it, ../gifs/ rewritten to gifs/) and self-scores the pre-publish audit: path rewrite, no secrets /
# local paths, self-contained assets (no broken srcs), outbound links, and the version badge.
#
# It does NOT deploy — that step needs interactive `npx wrangler login` and is left to the human
# (see the skill's SKILL.md, "Deploy"). Exits non-zero if any audit gate fails.
#
# Usage (from anywhere):  .claude/skills/publish-cover/scripts/build-cover-dist.sh
#
set -uo pipefail

# repo root = four levels up from .claude/skills/publish-cover/scripts/
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT"

COVER=docs/cover.html
DIST=tmp/cover-dist
fail=0

[ -f "$COVER" ] || { echo "FAIL: $COVER not found (is this the repo root?)"; exit 1; }

# --- 1. assemble the bundle ---
rm -rf "$DIST" && mkdir -p "$DIST/gifs"
grep -oE 'gifs/[A-Za-z0-9._-]+\.gif' "$COVER" | sort -u | sed 's#gifs/##' \
  | while read -r g; do cp "gifs/$g" "$DIST/gifs/$g" 2>/dev/null || echo "WARN: gifs/$g referenced but missing"; done
sed 's#\.\./gifs/#gifs/#g' "$COVER" > "$DIST/index.html"

echo "--- bundle contents ---"; find "$DIST" -type f | sort

# --- path rewrite ---
if grep -q '\.\./gifs/' "$DIST/index.html"; then echo "FAIL: stray ../gifs path remains"; fail=1; else echo "PASS: paths rewritten"; fi

# --- 2.2 no secrets / local-only leakage ---
if grep -n -I -iE "api[_-]?key|secret|token|password|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|/Users/[a-z]+|env-secrets" "$DIST/index.html"; then
  echo "^^ FAIL: review each hit (secret / local path in cover)"; fail=1
else echo "PASS: no secrets / local paths"; fi

# --- 2.3 self-contained: every referenced non-data src exists locally ---
while read -r p; do
  [ -z "$p" ] && continue
  if [ -f "$DIST/$p" ]; then echo "OK   $p"; else echo "MISS $p"; fail=1; fi
done < <(grep -oE 'src="[^"]+"' "$DIST/index.html" | sed 's/src="//;s/"//' | grep -v '^data:')

# --- 2.4 outbound links (eyeball: expect only the intended repo URL) ---
echo "--- outbound links ---"
grep -oE 'href="https?://[^"]+"' "$DIST/index.html" | sort -u

# --- version badge (drifts silently; confirm it matches the release you are shipping) ---
echo "--- version badge in bundle ---"
grep -oE 'class="badge">v[0-9.]+' "$DIST/index.html" | sed 's/class="badge">//' || echo "(no version badge found)"

echo
if [ "$fail" -eq 0 ]; then
  echo "AUDIT: ALL PASS. Deploy with:"
  echo "  npx -y wrangler login            # once, interactive"
  echo "  npx wrangler pages deploy $DIST --project-name=menubar-load-runner --commit-dirty=true"
else
  echo "AUDIT: FAIL — fix the above before deploying."
fi
exit "$fail"
