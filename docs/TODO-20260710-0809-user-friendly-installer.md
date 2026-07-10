# TODO — User-friendly installer (curl|bash source-compile)

Created: 2026-07-10 08:09

## Goal

Ship a one-line, self-hosted installer for MenuBar Load Runner that is safe, inspectable,
tag-pinned, and cleanly reversible — without depending on Homebrew or Apple notarization.

## Context & decision

Researched 2026 OSS practice for macOS menu-bar apps. Mainstream best practice is a
signed + notarized `.app` shipped via **GitHub Releases + Homebrew Cask + Sparkle**. Two
hard constraints rule that out *for now*:

- **Homebrew** promotion isn't feasible until the project has enough GitHub stars / mentions
  (and a cask would need notarization anyway).
- **Apple Developer ID / notarization** is slow and unreliable to obtain; we don't want to
  block on Apple review.

Given the app is deliberately source-only (single `.swift` file, no Xcode project, no `.app`
bundle, no signing; launcher self-compiles with `swiftc`; runtime reads `gifs/` + `presets.json`
relative to source), **curl|bash + git-clone + compile** is the correct fit — it needs no
external gatekeeper and matches the existing self-compile + LaunchAgent design. The only gap
vs. best practice is integrity/verification, which we close with the tasks below (all free,
no external dependency).

Reference design checked: `unhappychoice/gitlogue` `install.sh` (prebuilt-binary model; we
adapt its UX flow — banner, platform preflight, PATH hint, `VERSION` arg — to a source model).

## Scope (this task)

1. Harden `install.sh` (already drafted at repo root).
2. Add `uninstall.sh`.
3. Rewrite the README "Install" section (lead with download-and-inspect).
4. Smoke-test everything into `./tmp/` (per CLAUDE.md scratch rule) — no touching real
   `~/.local` or `~/Library/LaunchAgents`.

---

## Tasks

### 1. Trim `install.sh` to MVP

Scope reduced after an MVP review (2026-07-10): tag-pinning / `VERSION` / `--ref` were deferred
as over-scoped for a first cut — see Out of scope. The installer installs the latest default
branch; power users can `git -C <dir> checkout` a tag themselves.

- [ ] **Drop `--ref`** and its clone/update branching (removes the fragile
      `${REF:+--branch "$REF"}` quoting and the detached-HEAD `pull` no-op).
- [ ] **Simplify fetch/update** to: fresh → `git clone`; existing → `git pull --ff-only`.
- [ ] **Drop `--no-login`** — the prompt already auto-skips with no TTY (the `curl | bash` case),
      which is the safe default. Keep the `[y/N]` prompt via `/dev/tty` + `--login` for automation.
- [ ] **Replace the `usage()` sed-parse** (fragile hardcoded `2,32p` line range) with a small
      hardcoded heredoc.
- [ ] Keep: macOS-only guard, `git`+`swiftc` preflight → `xcode-select --install` hint, precompile
      with graceful on-demand fallback (fail-fast at install time), symlink into `BIN_DIR`, PATH
      guidance, `describe --tags` in the success line.
- [ ] Keep env overrides: `MENUBAR_LOAD_RUNNER_HOME`, `BIN_DIR`, `MENUBAR_LOAD_RUNNER_REPO_URL`
      (the last is test scaffolding for `./tmp/` smoke tests; harmless).
- [ ] Update the in-file header comment to match (no `--ref`/`--no-login`; installs latest).

### 2. Add `uninstall.sh`

- [ ] Remove the launcher symlink at `$BIN_DIR/menubar-load-runner` (only if it points into the
      install dir — don't clobber an unrelated file of the same name).
- [ ] If a LaunchAgent is installed, run the app's existing
      `scripts/uninstall-login-item.sh` (or bootout + remove plist directly if the script is
      absent) so start-at-login is torn down.
- [ ] `pkill -f 'MenuBarLoadRunner'` any running instance (best-effort).
- [ ] Remove the install dir (`$MENUBAR_LOAD_RUNNER_HOME`), with a confirm `[y/N]` before `rm -rf`
      (skippable with `--yes`); refuse if the dir isn't our git checkout.
- [ ] Same env overrides + colored output style as `install.sh`; leave no residue.

### 3. README "Install" section

- [ ] Add an **Install** section near the top (before "Run Locally"), leading with the
      **download-and-inspect** form as the recommended path:
      ```bash
      curl -fsSL https://raw.githubusercontent.com/binlecode/menubar-load-runner/main/install.sh -o install.sh
      less install.sh          # inspect before running
      bash install.sh
      ```
- [ ] Show the **curl|bash one-liner** as the convenience shortcut, clearly labelled.
- [ ] Document: what it installs (app → `~/.local/share/menubar-load-runner`, launcher symlink
      → `~/.local/bin`), the Xcode CLT prerequisite, tag-pin default + `VERSION`/`--ref`, env
      overrides, the login prompt, and `uninstall.sh`.
- [ ] Add `install.sh` / `uninstall.sh` to the **Files** list.
- [ ] Cross-reference the existing "Start at login" section (installer's prompt calls the same
      LaunchAgent script — don't duplicate mechanics).

### 4. Verify (smoke test into `./tmp/`)

- [ ] Fresh install from **local** repo (`MENUBAR_LOAD_RUNNER_REPO_URL=file://$(pwd)`,
      `MENUBAR_LOAD_RUNNER_HOME=tmp/…`, `BIN_DIR=tmp/…`, `--no-login`): clone → tag checkout →
      build → symlink; exit 0.
- [ ] Confirm the resolved ref is the **latest tag** (currently `v1.5.1`), not `main`.
- [ ] Re-run installer → takes **Updating existing install** path (no clone), exit 0.
- [ ] Installed launcher runs (`--help` renders).
- [ ] `VERSION`/`--ref` selects a specific tag (e.g. `v1.4.0`) — verify `describe --tags`.
- [ ] `install.sh --help` and `uninstall.sh --help` render.
- [ ] `uninstall.sh --yes` removes symlink + install dir, leaves no residue; refuses on a
      non-checkout dir.
- [ ] Clean up `tmp/` after.

---

## Acceptance criteria

- One-line install works end-to-end on a clean-ish macOS with Xcode CLT present.
- Default install is **tag-pinned** (immutable), inspectable before run, and reports the exact ref.
- Re-running upgrades in place; `uninstall.sh` fully reverses install (symlink, dir, LaunchAgent).
- No dependency on Homebrew, GitHub API tokens, or Apple signing/notarization.
- README leads with the safe (inspect-first) form; curl|bash shown as convenience.
- All verification done in `./tmp/`; nothing written to real `~/.local` or `~/Library/LaunchAgents`.

## Out of scope / future (revisit when stars justify it)

- **Tag-pinning + `VERSION`/`--ref` arg** (deferred from task 1 as non-MVP). Default install to
  the latest release tag (resolve via `git tag --sort=-v:refname | head -1`, no GitHub API), with
  a positional `VERSION` / `--ref` override and the resolved ref reported for immutability. Add
  once the basic installer is proven; it's the main "safe curl|bash" hardening still on the table.
- **Homebrew tap** with a *source* `formula` (`depends_on :xcode`, builds from tag) →
  `brew install binlecode/tap/menubar-load-runner` + `brew upgrade`. Only real package-manager
  path open without notarization; layer on top later without changing this installer.
- **Signed + notarized `.app` + Sparkle + Homebrew Cask** — full mainstream GUI distribution.
  Requires Apple Developer ID ($99/yr) + notarization pipeline; contradicts current source-only,
  no-signing ethos. Deferred until/unless the project pivots to general-audience distribution.
- **Checksum/signature of `install.sh` itself** — meaningful only once releases are cut with a
  published checksum; note it when release automation exists.

## Follow-ups after merge

- [ ] Update `CHANGELOG.md` (new "Install" tooling) and bump version if releasing.
- [ ] Push `install.sh` to `main` so the raw.githubusercontent.com one-liner URL resolves
      (the curl|bash URL only works once the script is on the default branch).
- [ ] Consider a short asciinema/GIF of the install flow for the README.
