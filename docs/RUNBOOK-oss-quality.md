# Runbook: raise this repo to high-quality OSS status

A prioritized, checklist-driven playbook for bringing MenuBar Load Runner up to 2026
frontier-grade open-source standards — the community-health layer, the agentic-tooling layer, and
CI/release automation — **without** re-doing the parts this repo already does well, and **without**
contradicting the scope decisions already recorded in `CLAUDE.md`.

## How to use this runbook

- Work top-to-bottom by phase; phases are ordered by leverage (P0 = do first).
- Every task has **Why / Do / Done-when**. Check the box when *Done-when* is objectively true.
- `[~]` marks work already done or partially in place — verify, don't rebuild.
- Effort tags: `S` ≤30 min · `M` a focused session · `L` multi-session.
- This is a *source-compiled, single-file macOS app with no package registry and no unit-test
  suite*. Best practices are adapted to that reality (e.g. "CI" means running the existing QA
  runbook on a macOS runner, not `npm test`; "provenance" is scoped down because there is no
  released binary artifact).

## Definition of done ("high quality OSS")

The repo is "there" when all of the following hold:

1. GitHub **Insights → Community Standards** shows a full green checklist.
2. A first-time contributor can go from clone → change → validated PR using only in-repo docs.
3. An AI coding agent (Claude Code, Codex, Copilot, Cursor, …) picks up project conventions from a
   standard file without being told.
4. Every push and PR is gated by automated build + QA on a real macOS runner.
5. Cutting a release is a documented, mostly-automated, tamper-evident sequence.
6. Security reports have a private, documented channel.

---

## Baseline audit (2026-07-10)

| Area | Artifact | State |
|---|---|---|
| Legal | `LICENSE.md` (MIT) | ✅ present |
| Docs | `README.md`, `CHANGELOG.md` (Keep-a-Changelog + semver + public-API contract) | ✅ strong |
| Docs | `docs/DESIGN-system.md`, `docs/RUNBOOK-qa-release.md`, `docs/RUNBOOK-pages-publish.md` | ✅ strong |
| Agentic | `CLAUDE.md` (rich, authoritative) | ✅ excellent |
| Agentic | `AGENTS.md` (cross-tool standard) | ❌ missing |
| Community | `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `SUPPORT.md` | ❌ missing |
| Community | `.github/` issue forms, PR template, CODEOWNERS, FUNDING | ❌ missing |
| Automation | CI (build + QA on macOS runner) | ❌ missing |
| Automation | Release automation / provenance | ❌ missing |
| Discovery | Repo description, topics, README demo GIF, badges | ⚠️ partial |

The single highest-leverage fact: **`docs/RUNBOOK-qa-release.md` is already a copy-pasteable,
self-scoring test script.** CI is mostly a matter of running its blocks on a macOS runner — see
Phase 4. Do not write a new test harness.

---

## Phase 1 — Community-health & legal foundation (P0)

These are what GitHub's Community Standards checklist grades, and what a contributor looks for first.

- [ ] **1.1 `CONTRIBUTING.md`** · `M`
  - Why: tells humans (and agents) how to build, validate, and submit changes; GitHub links it
    automatically on every new issue/PR.
  - Do: cover — the dev loop (edit `MenuBarLoadRunner.swift`, re-run `./menubar-load-runner`); the
    warning-clean `swiftc -O -strict-concurrency=complete` build gate; **required pre-PR step: run
    `docs/RUNBOOK-qa-release.md` §1–6 and paste the PASS/FAIL summary into the PR**; where magic
    numbers go (`Tuning`) and presets go (`gifs/presets.json`, no Swift edit); commit/PR
    expectations; the semver/public-API contract (link `CHANGELOG.md`'s "Public API" section).
    Keep it thin and link `CLAUDE.md` / `DESIGN-system.md` rather than duplicating architecture.
  - Done-when: a new contributor can build, validate, and open a compliant PR using only this file
    plus the docs it links.

- [ ] **1.2 `CODE_OF_CONDUCT.md`** · `S`
  - Why: baseline expectation for a public project; part of the Community Standards checklist.
  - Do: adopt Contributor Covenant v2.1 verbatim; fill in the enforcement contact.
  - Done-when: file present with a real contact address.

- [ ] **1.3 `SECURITY.md`** · `S`
  - Why: gives a *private* disclosure path (GitHub renders a "Report a vulnerability" affordance).
  - Do: state supported versions (latest tag), the reporting channel (enable **Private
    vulnerability reporting** in repo Settings → Security, and/or a contact), and expected response
    time. Note the app's low attack surface honestly: it only *reads* unprivileged system metrics
    (Mach/sysctl/IORegistry), runs unsigned from source, and has no network client — so the real
    risks are the `curl | bash` installer and the compile-from-source trust model. Point readers to
    the "inspect before running" install path already in the README.
  - Done-when: Private vulnerability reporting is enabled and `SECURITY.md` documents the channel.

- [ ] **1.4 `SUPPORT.md`** · `S`
  - Why: routes "how do I…" away from the bug tracker.
  - Do: point users to README troubleshooting, `--help`, the log file
    (`/tmp/menubar-load-runner.log`), and GitHub Discussions (Phase 5) for questions vs. Issues for
    bugs.
  - Done-when: present and linked from the issue chooser.

- [ ] **1.5 Confirm license detection** · `S`
  - Why: GitHub's license widget and downstream tooling key off the license file.
  - Do: confirm the repo sidebar shows "MIT License" (GitHub detects `LICENSE.md`). Ensure the
    copyright line and year are current. Leave as `LICENSE.md` unless the widget fails to detect it,
    in which case rename to `LICENSE`.
  - Done-when: repo sidebar shows the detected MIT license.

---

## Phase 2 — `.github/` contributor infrastructure (P0–P1)

- [ ] **2.1 Issue Forms (YAML), not legacy templates** · `M`
  - Why: structured forms produce triageable, complete reports and are the 2026 default.
  - Do: `.github/ISSUE_TEMPLATE/bug_report.yml` (required fields: macOS version, chip
    Intel/Apple-Silicon, app version from `--help`/About, load source in use, preset, exact launch
    command, relevant lines from `/tmp/menubar-load-runner.log`, repro steps) and
    `feature_request.yml`. Add `.github/ISSUE_TEMPLATE/config.yml` with `blank_issues_enabled: false`
    and `contact_links` to Discussions/SUPPORT.
  - Done-when: "New issue" shows the two forms + the config links, no blank-issue option.

- [ ] **2.2 `.github/PULL_REQUEST_TEMPLATE.md`** · `S`
  - Why: enforces the validation contract on every PR.
  - Do: checklist — build is warning-clean; `docs/RUNBOOK-qa-release.md` §1–6 pasted; `CHANGELOG.md`
    `[Unreleased]` updated; version/public-API impact considered; preset changes touched all four
    sync points from `CLAUDE.md` ("Adding a new built-in preset").
  - Done-when: new PRs pre-fill the checklist.

- [ ] **2.3 `.github/CODEOWNERS`** · `S`
  - Why: auto-requests review; signals ownership.
  - Do: assign the maintainer to `*`; consider a stricter owner on `gifs/presets.json` and
    `MenuBarLoadRunner.swift`.
  - Done-when: opening a PR auto-requests the owner.

- [ ] **2.4 `.github/FUNDING.yml`** *(optional)* · `S`
  - Do: add sponsor links if desired, else skip. Done-when: decided.

- [ ] **2.5 `.github/dependabot.yml`** *(scoped)* · `S`
  - Why: the app has **no package-manager dependencies** (one Swift file, no SwiftPM manifest), so
    dependabot has nothing to bump *until CI exists*. Once Phase 4 adds workflows, point dependabot
    at the `github-actions` ecosystem to keep action versions patched.
  - Done-when: after Phase 4, dependabot watches `github-actions` (weekly). Skip until then and note
    it here so it isn't forgotten.

---

## Phase 3 — Agentic layer (the "frontier" ask)

Context: `AGENTS.md` is now the cross-tool standard for agent instructions — originated by OpenAI
(Aug 2025), donated to the Linux Foundation's Agentic AI Foundation (Dec 2025), read natively by
Codex, Copilot, Cursor, Windsurf, Aider, Zed, Jules, JetBrains Junie, and others; ~60k+ repos by
mid-2026. **Claude Code reads `AGENTS.md` too, but `CLAUDE.md` remains its richer native format.**
This repo's `CLAUDE.md` is already excellent — the move is to *expose* it to every other agent, not
to fork it.

**Repo convention (do not violate):** `CLAUDE.md` **stays the lean, canonical top-level agent file**
— kept high signal-to-noise and context-focused on the build/run/validate loop and the load-bearing
rules. Specialized, verbose, or narrow rules do **not** go into `CLAUDE.md`; they live in `docs/`
(SDLC docs, design, runbooks) or `.claude/`, referenced by exact path. `AGENTS.md` follows the same
discipline — a thin cross-tool entry point, not a second home for detail.

- [ ] **3.1 Add `AGENTS.md` as a thin cross-tool pointer to `CLAUDE.md`** · `S`
  - Why: non-Claude agents (Codex/Copilot/Cursor/…) read the standard location; `CLAUDE.md` should
    stay canonical without being duplicated or bloated.
  - Do: keep `CLAUDE.md` as the single source of truth. Add a short `AGENTS.md` that points to it —
    either a symlink (`ln -s CLAUDE.md AGENTS.md`, if GitHub + your target agents follow link
    targets — test first) or a minimal stub that says "this project's agent instructions live in
    `CLAUDE.md`; specialized rules live under `docs/` and `.claude/`" plus the two or three
    load-bearing rules an agent needs before reading further (build/run loop, the QA-runbook gate,
    `tmp/`-only scratch files, presets are data in `gifs/presets.json`). Do **not** copy the full
    `CLAUDE.md` into `AGENTS.md` — that reintroduces the drift/SNR problem the convention avoids.
  - Done-when: a non-Claude agent finds project conventions via `AGENTS.md`; there is exactly one
    canonical body of agent rules (`CLAUDE.md`) and it did not grow to accommodate this.

- [ ] **3.2 Keep the agent entry files lean and machine-navigable** · `S`
  - Why: SNR is the point — the entry file should *route*, not contain everything.
  - Do: ensure `CLAUDE.md` (and the `AGENTS.md` pointer) link the QA runbook, DESIGN doc, this
    runbook, and the preset-adding procedure by exact path; keep the "single source of truth"
    callouts (`gifs/presets.json`, `Tuning`). When a rule gets long or niche, move it to `docs/` or
    `.claude/` and leave a one-line pointer — don't inline it.
  - Done-when: every "where does X live" question is one hop from the entry file, and neither entry
    file carries detail that belongs in `docs/`/`.claude/`.

- [ ] **3.3 (Optional) tool-specific shims** · `S`
  - Do: only if you actually use them, add `.github/copilot-instructions.md` / `.cursor/rules`
    pointing at `AGENTS.md`. Don't proliferate copies — each is a drift risk.
  - Done-when: decided; any shim added just references the canonical file.

---

## Phase 4 — CI / CD automation (P1) — *the biggest quality jump*

There is no unit-test suite, but there **is** a rigorous, self-scoring QA runbook. Turn it into CI.

- [ ] **4.1 Build + QA workflow on macOS runner** · `M–L`
  - Why: every push/PR proves the app still compiles warning-clean and passes the reader/scaler/CLI
    checks — the core correctness contract.
  - Do: `.github/workflows/ci.yml`, `runs-on: macos-14` (or latest), triggered on push + PR.
    Steps translate `docs/RUNBOOK-qa-release.md`:
    1. **Build gate** — `swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o
       tmp/mblr-check`; **fail the job on any compiler output** (warnings included).
    2. **§2 CLI parse paths** — run the block; fail if `fails>0`.
    3. **§3 launch lifecycle** — uses `MENUBAR_LOAD_RUNNER_EXIT_AFTER` so the GUI self-terminates;
       exercise cpu/memory + `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE` fallbacks. Verify GUI apps can
       instantiate a status item on the runner; if headless blocks it, gate §3/§7-style steps behind
       a note and keep §2/§5/§6 (which don't need the menu bar).
    4. **§4 error paths**, **§5 reader ranges**, **§6 scaler behavior** — each already exits
       non-zero on failure; wire that to the job status.
  - Note (no silent gaps): document in the workflow which runbook sections run in CI vs. remain
    manual (§7 interactive spot-check, and any step blocked by the headless runner). Don't let CI
    imply coverage it doesn't have.
  - Done-when: a red CI blocks merge on any build warning or QA failure; branch protection requires
    it on `main`.

- [ ] **4.2 Branch protection on `main`** · `S`
  - Do: require the CI check + at least one review (CODEOWNERS) before merge; disallow force-push.
  - Done-when: `main` cannot be pushed to directly and requires green CI.

- [ ] **4.3 Release workflow** · `M`
  - Why: make cutting a release repeatable and tie it to the existing semver/CHANGELOG discipline.
  - Do: `.github/workflows/release.yml` triggered on `v*` tags — validate the tag's version matches
    `AppInfo.version` and that `CHANGELOG.md` has a matching section (both already asserted in QA
    §2), then create a GitHub Release whose notes are extracted from that CHANGELOG section. Because
    the app is **install-from-source**, there is no compiled artifact to attach — the "release" is
    the tag + notes + the installer pulling `main`/the tag.
  - Done-when: pushing `vX.Y.Z` produces a Release with CHANGELOG-derived notes and a version-match
    check.

- [ ] **4.4 Supply-chain hardening (scoped)** · `S–M`
  - Why: the trust model here is `curl | bash` + compile-from-source, not a downloaded binary — so
    full SLSA binary provenance doesn't apply, but the *distribution path* still deserves hardening.
  - Do: pin all GitHub Actions to commit SHAs; set minimal `permissions:` in each workflow; enable
    OpenSSF Scorecard action for an ongoing hygiene grade. Keep the README's "inspect before running"
    install guidance prominent. **Deliberately deferred (see `CLAUDE.md`): signed/notarized `.app`,
    Homebrew tap, SLSA artifact provenance** — revisit only if the project starts shipping binaries.
  - Done-when: actions are SHA-pinned with least-privilege permissions; Scorecard runs.

---

## Phase 5 — Discoverability & release polish (P2)

- [ ] **5.1 Repo metadata** · `S` — set a one-line description and topics (`macos`, `menubar`,
  `swift`, `appkit`, `status-bar`, `system-monitor`, `cpu`, `gif`). Done-when: description + topics
  set; repo surfaces in topic search.
- [ ] **5.2 README demo up top** · `S–M` — embed an animated GIF/screenshot of the menu-bar item and
  the menu near the top; add badges (license, latest release, CI status once Phase 4 lands).
  Done-when: a visitor sees what it does in the first screenful.
- [ ] **5.3 Enable Discussions** · `S` — Q&A + Ideas categories; link from SUPPORT and the issue
  chooser. Done-when: enabled and linked.
- [ ] **5.4 Project site** · `S` — `docs/RUNBOOK-pages-publish.md` and `docs/cover.html` already exist;
  publish GitHub Pages per that runbook and link it in the repo's "About". Done-when: Pages live and
  linked.
- [ ] **5.5 Release hygiene** · `S` — ensure the "About" dialog, `--help`, `CHANGELOG.md`, and the
  latest tag all agree (QA §2 checks this). Done-when: all four version surfaces match on the latest
  tag.

---

## Phase 6 — Governance & sustainability (P2–P3)

- [ ] **6.1 Versioning/compat policy** · `[~]` — already defined in `CHANGELOG.md`'s "Public API"
  section. Link it from `CONTRIBUTING.md` so it's discoverable. Done-when: linked.
- [ ] **6.2 Maintainers & roadmap** · `S` — a short `MAINTAINERS.md` (or a README section) naming the
  maintainer and decision process; optionally a lightweight roadmap (or convert `docs/TODO-*.md`
  into GitHub Issues/Milestones for public visibility). Done-when: ownership + direction are
  publicly legible.
- [ ] **6.3 OpenSSF Best Practices badge** *(optional, aspirational)* · `M` — pursue the passing
  badge once Phases 1–4 land; it externally validates most of this runbook. Done-when: badge earned
  or explicitly deferred.

---

## Suggested execution order

1. **Phase 1** (legal/community foundation) — unblocks the Community Standards checklist fastest.
2. **Phase 3.1** (`AGENTS.md`) — cheap, high-signal for the agentic goal.
3. **Phase 2** (`.github/` templates) — makes contribution real.
4. **Phase 4** (CI from the QA runbook) — the biggest correctness/quality jump; then enable branch
   protection and turn on dependabot for actions (2.5).
5. **Phase 5 / 6** — polish, discoverability, governance.

## Maintenance cadence (keep it high-quality)

- **Per PR:** CI green; `CHANGELOG.md` `[Unreleased]` updated; QA summary pasted.
- **Per release:** follow `docs/RUNBOOK-qa-release.md` "Cutting a release"; confirm all version
  surfaces agree; push tag → release workflow.
- **Monthly/quarterly:** re-check Community Standards checklist; bump SHA-pinned actions
  (dependabot PRs); keep `AGENTS.md`/`CLAUDE.md` in sync with any convention change; glance at the
  OpenSSF Scorecard grade.

---

### Sources / standards referenced

- [Creating a default community health file — GitHub Docs](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)
- [AGENTS.md Field Guide, 2026 edition](https://www.iuriio.com/blog/posts/2026/05/agents-md-field-guide-2026) · [AGENTS.md Guide (2026)](https://vibecoding.app/blog/agents-md-guide) · [Top AI Agent Standards 2026](https://blog.agentailor.com/posts/top-ai-agent-standards-2026)
- [slsa-framework/slsa-github-generator](https://github.com/slsa-framework/slsa-github-generator) · [SLSA provenance with GitHub Actions](https://devopscube.com/slsa-provenance/)
- Contributor Covenant v2.1 (Code of Conduct) · Keep a Changelog 1.1.0 · Semantic Versioning 2.0.0 (both already adopted in `CHANGELOG.md`)
