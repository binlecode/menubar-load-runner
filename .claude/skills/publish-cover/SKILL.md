---
name: publish-cover
description: Publish or redeploy the marketing/design cover page (docs/cover.html) to Cloudflare Pages as <project>.pages.dev. Use when asked to publish, redeploy, or update the cover / landing / web page, or after cutting a release when the cover's version badge or embedded GIFs changed. Builds + audits the deploy bundle automatically; the authenticated deploy is a human step (interactive Cloudflare login).
---

# Publish the web cover

Publishes `docs/cover.html` (the marketing/design cover page) to the public web as a **curated
subset** of the repo — just the cover page and the GIFs it references, served as its own clean site
root. Deployed to **Cloudflare Pages** as `<project>.pages.dev` via `wrangler` **direct upload** (we
hand Cloudflare a built folder — no repo access, no build step of its own).

Live URL: `https://menubar-load-runner.pages.dev`. Scripts live in `scripts/` next to this file.

## What I can and can't do

- **Build + audit the bundle: automated** — run `scripts/build-cover-dist.sh` (below). Safe, deterministic.
- **Deploy: human step.** `npx wrangler` needs an interactive Cloudflare login (browser OAuth) or a
  `CLOUDFLARE_API_TOKEN`. If neither is present, build + audit, then hand the user the exact deploy
  commands to run via `!` — do not attempt the login.

## 0. Decision gate (read first)

- **Curated subset, not the repo.** The site is the *built bundle* (`cover.html` → `index.html` + only
  the GIFs it references), not the repo's files at repo-shaped URLs.
- **Third-party art goes public.** The cover embeds character GIFs (Ghibli / Pinterest). Displaying
  them is the owner's call — a *content* decision, not a technical blocker. Already accepted on prior
  publishes; only re-flag if the art set changed.
- **Cloudflare account exists.** Free tier is enough.

## 1. Build + audit the bundle (automated)

```bash
.claude/skills/publish-cover/scripts/build-cover-dist.sh
```

Assembles `tmp/cover-dist/` and self-scores: path rewrite (`../gifs/`→`gifs/`), no secrets/local
paths, self-contained assets (no broken `src`), outbound links (expect only the repo URL), and prints
the version badge. Exits non-zero on any failure. Optionally eyeball it: `open tmp/cover-dist/index.html`.

**Version badge:** `docs/cover.html` carries a footer badge (e.g. `v1.7.1`) that is **not** covered by
the QA version-parity check, so it drifts silently (it has lagged a release before). Bump it in
`docs/cover.html` when you cut a release, rebuild, and redeploy so the public page matches the shipped
version. The script prints the badge it bundled — confirm it matches.

## 2. Deploy (human — interactive auth)

Run wrangler via `npx` (no global install). Direct upload grants Cloudflare no repo access.

```bash
npx -y wrangler login            # once: opens browser, authorize; token persists
npx wrangler pages deploy tmp/cover-dist --project-name=menubar-load-runner --commit-dirty=true
```

First run offers to create the project; accept. Re-running the same command redeploys to the same URL.
The `pages.dev` namespace is global across all accounts — keep the distinctive `menubar-load-runner`
project name to avoid collisions.

## 3. Verify (live)

```bash
URL=https://menubar-load-runner.pages.dev
curl -sSI "$URL" | head -1                                   # expect: HTTP/2 200
grep -oE 'gifs/[A-Za-z0-9._-]+\.gif' tmp/cover-dist/index.html | sort -u \
  | while read -r g; do printf '%s ' "$g"; curl -sSo /dev/null -w '%{http_code}\n' "$URL/$g"; done
open "$URL"                                                  # eyeball layout + GIF smoothness
```

All `200`s and a page matching the local bundle = done.

## Notes

- **Snapshot, not live.** Editing `docs/cover.html` or a GIF does nothing to the live page until you
  rebuild (§1) + redeploy (§2). This is deliberate — the cover is a hand-curated snapshot, not a doc
  site that redeploys on every commit. (Hence direct upload over a GitHub-Pages / CF-Git integration.)
- **Independent surfaces.** The app reads the on-disk `gifs/`, and a Claude-hosted artifact bakes GIFs
  in as base64 — both are independent of this Pages site. Updating one does not update the others.
- **Assets:** see the `build-visuals` skill for (re)building the GIFs the cover embeds.
- **Teardown:** `npx wrangler pages project delete menubar-load-runner` (removes the site + URL);
  `rm -rf tmp/cover-dist`.
- **Reuse for other repos:** same flow — build a `tmp/cover-dist/`, deploy with a distinct
  `--project-name`. Identical whether the repo is public or private (direct upload sends only the folder).

## Scratch files

The bundle lives in `tmp/cover-dist/` (repo root) — throwaway, never committed.
