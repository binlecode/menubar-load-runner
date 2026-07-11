# Runbook: Publish the web cover → moved to the `publish-cover` skill

This runbook is now the **`publish-cover` skill** at
[`.claude/skills/publish-cover/SKILL.md`](../.claude/skills/publish-cover/SKILL.md), so the flow is
directly invocable (build + audit is automated via `scripts/build-cover-dist.sh`; the authenticated
Cloudflare deploy stays a human step).

Publishing `docs/cover.html` to Cloudflare Pages (`menubar-load-runner.pages.dev`) via `wrangler`
direct upload — decision gate, bundle build, pre-publish audit, deploy, verify, redeploy, teardown,
and the version-badge drift reminder — all live in the skill. Invoke it with `/publish-cover` or ask
to "publish/redeploy the cover".
