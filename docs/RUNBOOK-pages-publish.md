# Runbook: Publish the web cover

How to publish `docs/cover.html` (the marketing/design cover page) to the public web as a **curated
subset** of the repo — just the cover page and the GIFs it references, served as its own clean site
root, decoupled from the repo's structure and history. We deploy to **Cloudflare Pages** as
`<project>.pages.dev` using `wrangler` **direct upload** (we hand Cloudflare a built folder; it gets
no repo access and no build step of its own).

Work through the phases in order. Each step is copy-pasteable from the repo root and self-scoring
(PASS/FAIL) or prints something to eyeball. Phase 3 (the flip to public web) happens **after** the
audit in Phase 2.

> **Why direct upload, given the repo is public (MIT)?** The repo being open source doesn't make it
> the right *site root*: the cover is one HTML file that references a handful of GIFs via `../gifs/`,
> not a `/`-rooted site, and `gifs/` also holds preset art the cover doesn't use. Direct upload lets
> us publish exactly that curated bundle (page → `index.html`, only the referenced GIFs beside it)
> with no repo-shaped URLs, no build config, and no auto-deploy coupling to `main`. It's also
> repo-agnostic: one free Cloudflare account fans out to many `*.pages.dev` sites regardless of where
> each cover lives.
>
> **Why not GitHub Pages / a CF Git integration?** Both are viable now that the repo is public and
> are the more conventional choice if you want push-to-deploy of a `/docs` site. We prefer direct
> upload here because the cover is a hand-curated snapshot, not a doc site that should redeploy on
> every commit — see §5 for the deliberate "snapshot, not live" trade-off. See `build-visuals` for
> the visual assets themselves.

---

## 0. Decision gate (read first)

- [ ] **We publish a curated subset, not the repo.** Even though the repo is public, the site is
      just the *built bundle* (`cover.html` → `index.html` + the GIFs it references) — not the repo's
      files at repo-shaped URLs.
- [ ] **Third-party art is going public.** The cover embeds character GIFs (Ghibli / Giphy /
      Pinterest). Publishing a page that *displays* them is a lower-exposure, higher-visibility act
      than shipping the files in an OSS repo, but it is **not zero risk** — see §2.1. Decide you're
      comfortable, or swap the cover to assets you own.
- [ ] **Cloudflare account exists.** Free tier is enough (unlimited projects, unlimited bandwidth).

---

## 1. Build the deploy bundle

`docs/cover.html` references the GIFs as `../gifs/*.gif`. For a clean site root we assemble a
throwaway `tmp/cover-dist/` where the page is `index.html` and the GIFs sit beside it, rewriting the
`../gifs/` paths to `gifs/`. Nothing here is committed.

```bash
# from repo root
rm -rf tmp/cover-dist && mkdir -p tmp/cover-dist/gifs

# copy only the GIFs the cover actually references (not the whole gifs/ dir)
grep -oE 'gifs/[A-Za-z0-9._-]+\.gif' docs/cover.html | sort -u | sed 's#gifs/##' \
  | while read -r g; do cp "gifs/$g" "tmp/cover-dist/gifs/$g"; done

# page -> index.html, with ../gifs/ rewritten to gifs/
sed 's#\.\./gifs/#gifs/#g' docs/cover.html > tmp/cover-dist/index.html

echo "--- bundle contents ---"; find tmp/cover-dist -type f | sort
# PASS if index.html + every referenced gif is present, and no '../gifs' remains:
grep -q '\.\./gifs/' tmp/cover-dist/index.html && echo "FAIL: stray ../gifs path" || echo "PASS: paths rewritten"
```

Sanity-check the bundle in a browser before it goes anywhere public:

```bash
open tmp/cover-dist/index.html   # gifs must all load; dog should look as smooth as the others
```

---

## 2. Pre-publish audit (what's about to go public)

Scope is just `tmp/cover-dist/` — the only bytes that get uploaded. Much narrower than an OSS release
(no source, no history).

### 2.1 Asset licensing ⚠️

The cover displays copyrighted/trademarked characters (Totoro / Chihiro — Studio Ghibli; horse — a
"Pinterest silhouette" of unknown provenance). Hosting a page that shows them is your call, but be
aware it's third-party IP. Lower-risk alternatives if you'd rather not: feature only the assets you
own on the cover, or replace the character GIFs with original/CC0 art. This is a *content* decision,
not a technical blocker.

### 2.2 No secrets / no local-only leakage in the page

```bash
# the page is static design markup, but confirm nothing sensitive rode along
grep -n -I -iE "api[_-]?key|secret|token|password|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|/Users/[a-z]+|env-secrets" \
  tmp/cover-dist/index.html && echo "^^ REVIEW each hit" || echo "PASS: no secrets / local paths in cover"
```

(Absolute `/Users/...` paths or `~/env-secrets` references would leak your setup — there should be
none; the cover is self-contained markup + relative GIF paths.)

### 2.3 Bundle is self-contained

```bash
# every asset the page references must exist locally (no external hotlinks / broken srcs)
grep -oE 'src="[^"]+"' tmp/cover-dist/index.html | sed 's/src="//;s/"//' \
  | grep -v '^data:' | while read -r p; do
      [ -f "tmp/cover-dist/$p" ] && echo "OK   $p" || echo "MISS $p"; done
# any MISS = a broken image once published; fix before deploying.
```

### 2.4 Outbound links go where you intend

The cover now links out (the GitHub CTA in the header + a repo link in the footer). A public landing
page with a wrong or dead call-to-action is worse than none, so eyeball every external link:

```bash
grep -oE 'href="https?://[^"]+"' tmp/cover-dist/index.html | sort -u
# expect only the intended repo URL(s), e.g. https://github.com/binlecode/menubar-load-runner
```

---

## 3. Deploy to Cloudflare Pages (direct upload)

One-time: authenticate. We run wrangler via `npx` (no global install — nothing left behind, always
current). Direct upload grants Cloudflare **no** repo access — it just pushes the folder.

```bash
npx -y wrangler login            # interactive: opens browser; authorize once (token persists)
```

Deploy. Project name → subdomain, so pick something distinctive (the `pages.dev` namespace is global
across all accounts — prefix to avoid collisions):

```bash
npx wrangler pages deploy tmp/cover-dist \
  --project-name=menubar-load-runner \
  --commit-dirty=true
```

First run offers to create the project; accept. Output prints the live URL
(`https://menubar-load-runner.pages.dev`). Re-running the same command redeploys to the same URL.

---

## 4. Verify (live)

```bash
URL=https://menubar-load-runner.pages.dev
curl -sSI "$URL" | head -1                                   # expect: HTTP/2 200
# every referenced gif returns 200:
grep -oE 'gifs/[A-Za-z0-9._-]+\.gif' tmp/cover-dist/index.html | sort -u \
  | while read -r g; do printf '%s ' "$g"; curl -sSo /dev/null -w '%{http_code}\n' "$URL/$g"; done
open "$URL"                                                  # eyeball: layout + dog smoothness
```

All `200`s and a page that matches the local bundle = PASS.

---

## 5. Update / redeploy

The site is a snapshot — editing `docs/cover.html` or a GIF does **not** change the live page until
you rebuild + redeploy:

```bash
# rebuild the bundle (Phase 1) then:
npx wrangler pages deploy tmp/cover-dist --project-name=menubar-load-runner --commit-dirty=true
```

> **Version badge:** `docs/cover.html` carries a footer version badge (e.g. `v1.6.0`) that is **not**
> covered by the QA §2 version-parity check, so it drifts silently (it lagged a full release once).
> Bump it in `docs/cover.html` when you cut a release, then rebuild + redeploy so the public page
> matches the shipped version.

> **Note:** the app itself reads the live `gifs/` on disk, and the Claude-hosted **artifact** (if any)
> bakes the GIFs in as base64 — both are independent of this Pages site. Updating one does not update
> the others.

---

## 6. Optional: custom domain

Cloudflare Pages → your project → **Custom domains** → add e.g. `menubar.example.com`. If the domain's
DNS is already on Cloudflare it's a click; otherwise add the shown CNAME. TLS is automatic.

## 7. Teardown

```bash
npx wrangler pages project delete menubar-load-runner     # removes the site + its *.pages.dev URL
rm -rf tmp/cover-dist
```

---

### Reusing this for other repos

Same flow per repo, public or private: build a `tmp/cover-dist/`, `npx wrangler pages deploy …
--project-name=<distinct>`. One free Cloudflare account fans out to many `*.pages.dev` sites, and
because it's direct upload the flow is identical regardless of a repo's visibility.
