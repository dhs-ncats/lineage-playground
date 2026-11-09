# Rulesets for merge-to-publish

Two branch rulesets back the sync design (`lineage-rework/design.md`):

- `develop-protection.json` — develop is append-only for everyone
  except the bypass actors: linear history, no force-push, no
  deletion. The publish App and the operators team (break-glass
  `publish.sh` / runbook §8) are the only bypasses. Note the effect
  on ordinary PRs: "Create a merge commit" is unavailable;
  rebase-merge and squash both remain.
- `lineage-sync-base.json` — the decoy bases: merging a PR into one
  requires 1 approval and a green `lineage/verify` status (posted by
  `sync.sh --push` after the 7 acceptance checks). **Merge method is
  restricted to a merge commit** — this is load-bearing, not taste:
  `lineage-publish.yml` recovers the snapshot and the reviewed SHA
  from the merge commit's two parents; a squash or rebase merge has
  no second parent and the publish aborts.

## Importing

Fill in the `actor_id` placeholders first:

- `Integration` — the publish GitHub App's **App ID** (app settings
  page).
- `Team` — the operators team's numeric ID
  (`gh api orgs/cisagov/teams/<slug> --jq .id`).

Per repo:

```bash
gh api repos/cisagov/<repo>/rulesets --input develop-protection.json
gh api repos/cisagov/<repo>/rulesets --input lineage-sync-base.json
```

Fleet-wide, prefer one **org** ruleset per file instead
(`gh api orgs/cisagov/rulesets --input …`); org rulesets additionally
need a `conditions.repository_name` (or repository-property) block
listing the linearized repos — add it before importing, and extend it
as the campaign publishes more skeletons.

## Caveats

- Rulesets apply to admins too (no classic-protection admin
  loophole) unless listed as bypass actors. That is the point.
- `do_not_enforce_on_create` keeps the status-check rule from
  blocking the decoy branch's creation push. If your GitHub version
  also enforces the `pull_request` rule on branch creation, the
  operators-team bypass covers pushing decoys; bypass use is logged
  in ruleset insights, and the merge gate still binds everyone else.
- Signing is deliberately NOT a ruleset rule: cisagov does not
  require contributor signing, and `required_signatures` would impose
  it on every PR (and block rebase-merges, which GitHub leaves
  unsigned). The harness enforces signing on what it force-pushes
  instead (`publish.sh`; `verify-sync.sh` check 6), so rewritten
  history is always signed without burdening contributors.
