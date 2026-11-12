# Lineage rework — steady-state sync design (merge-to-publish)

How a linearized repo's ongoing skeleton syncs reach GitHub. The
local mechanics are runbook §5 (rebase onto the parent, rerere
auto-resolving); this document covers the GitHub side: the review
PR, why its merge button publishes via force-push, and the guardrails
around that. Prior-art survey: `research.md` (worklog §42); decision
record: worklog §43.

## Why not an off-the-shelf bot

A rebase sync replaces `develop`'s history: old develop is
`[old upstream][D1..Dn]`, the synced branch is
`[new upstream][D1'..Dn']`, and no Dn is an ancestor of Dn'. Two
consequences:

1. **No PR-based tool can complete the sync.** GitHub's merge button
   only appends to the base branch (merge commit re-braids and
   duplicates every downstream commit; squash flattens; rebase-merge
   replays the whole branch on top of old develop). The final act is
   always a non-fast-forward ref update — a force-push.
2. **Renovate specifically can't represent it.** Its unit of work is
   a single synthesized file-diff commit; even a first-class in-tree
   manager returns "changed files", never "this exact branch
   history". Its copier manager solves the same *shape* of dependency
   (one upstream template) but at tree level with a recorded SHA —
   abandoning shared ancestry, which is the premise of the
   linearization campaign.

So the harness executes the sync, and we borrow the PR-bot etiquette
(branch ownership checks, update-vs-recreate, one stable branch name)
instead of the PR-bot machinery.

## The flow

```
scripts/sync.sh <repo>          # local: clone, rebase onto parent,
                                #   rerere auto-resolve, verify 7/7
scripts/sync.sh --push <repo>   # interactive: push decoy + sync
                                #   branch, open/refresh the PR,
                                #   post the lineage/verify status
<review on GitHub>              # approve; required check is green
<click Merge>                   # merges into the DECOY, which
                                #   triggers lineage-publish.yml:
                                #   lease-guarded force-push of the
                                #   reviewed SHA to develop
```

### Branches

- `lineage/sync` — the sync branch: `origin/develop` rebased onto
  `upstream/develop`. Force-pushed (with lease) on every refresh.
  Deliberately **not** `lineage/skeleton`: that name belongs to
  action-lineage's hourly merge PRs (research §3); colliding with a
  live bot that pushes to it would be chaos.
- `lineage/sync-review` — the PR's head: ONE generated commit
  (machine-owned, regenerated and force-pushed on every refresh,
  deliberately unsigned, never published) whose *tree* is
  byte-identical to `lineage/sync` and whose *parent* is the develop
  snapshot. That makes the Files tab exactly the sync delta — normal
  inline review on the real change — the Commits tab one commit, and
  the merge clean by construction.
- `lineage/sync-base-<sha12>` — the **decoy** base the PR targets
  instead of develop: the develop snapshot itself, with its SHA also
  in the name and (in full) in the PR-body marker — it is the publish
  lease value, and the merge commit's first parent cross-checks it.
- `lineage/base` (a tag) — the parent tip this repo last synced onto,
  set by the publish workflow (from the `lineage-sync:onto` body
  marker). This is what makes tier ≥ 2 syncs tractable: a parent
  publish rewrites every inherited SHA, so a plain
  `rebase upstream/develop` would replay the repo's whole inherited
  stack; `sync.sh` instead rebases `--onto upstream lineage/base`,
  replaying **only this repo's own delta**. The same recorded base
  lets verify-sync's merge oracle work across parent republishes
  (synthetic merge-base). Absent tag (first sync, or tier-1 under the
  never-rewritten root) → full rebase, which is then equivalent.

### Why a decoy base

The PR exists for review, but its merge button must not touch
develop. Rather than fight the button (always-red required checks,
draft state), the decoy makes it harmless-and-useful: the merge goes
into a branch nobody consumes — develop is untouched by construction
— and the merge *event* is the publish trigger.

The decoy's tip must be an **ancestor of the head**, or GitHub greys
out the merge button whenever base and head conflict. The rebased
branch itself can never satisfy that against a develop snapshot (it
conflicts with the develop it was rebased from in exactly the hotspot
files) — which is why the head is the **review proxy**: a single
commit parented ON the snapshot, carrying the rebase result's tree.
Base = its parent ⇒ always mergeable; Files tab = exactly what will
change on develop; and the proxy can't smuggle anything past review,
because publish requires its tree to be byte-identical to
`lineage/sync` — the branch that actually gets published, with its
real per-commit, signed history.

The lease is self-enforcing: publish succeeds only if develop still
equals the recorded snapshot, so a wrong or tampered marker can only
make publish refuse, never overwrite.

### Merge-to-publish

`ci/lineage-publish.yml` (drop-in, merged to develop before the first
sync cycle) triggers on `pull_request_target: closed`.
Guards: `merged == true`, head is `lineage/sync-review`, base matches
`lineage/sync-base-*`. It then:

1. Reads the develop snapshot from the PR-body marker, cross-checked
   against the decoy's name AND the merge commit's first parent;
   verifies the reviewed proxy is the merge's second parent.
2. Verifies the reviewed proxy's **tree is byte-identical** to the
   recorded `lineage/sync` tip (`lineage-sync:pushed-sha` marker) —
   a mismatch means the sync branch changed after review; refuse.
3. Pushes **the real branch tip** (not the proxy) to develop with
   `--force-with-lease=develop:<snapshot>`. If anything reached
   develop mid-review, the lease fails instead of destroying it.
4. Records `lineage/base`, deletes all three review branches (decoy,
   sync, proxy), and comments the outcome on the PR (success, or
   refusal instructions: re-run `sync.sh`, fresh PR).

The workflow moves a ref; it creates no commits, so the
signed-commits policy is untouched — every commit above upstream was
signed locally during the rebase and verified before push.

`pull_request_target` runs the workflow definition from the repo's
**default branch** (confirmed against the GitHub docs, 2026-11-05) —
never from the sync branch or the decoy — so neither the upstream
commits being synced nor anything pushed to the PR can alter the
workflow that holds the publish credential.

### Credential

The force-push needs a bypass identity: a GitHub App listed as
bypass actor on develop's ruleset, its private key in an
environment-scoped secret (`lineage-publish`), minting a short-lived
installation token per run. This is the honest cost of
merge-to-publish versus the interactive model: the capability moves
from a human's keyboard into CI. Scope the app to the skeleton repos,
contents + pull-requests write only.

### Rulesets (`ci/rulesets/`)

- `develop`: block force-push + deletion, require linear history.
  Signing is deliberately not a ruleset rule — cisagov doesn't
  require contributor signing; the harness signs what it force-pushes
  (`publish.sh`, `verify-sync.sh` check 6). Bypass: the publish app
  (and the operators team, for break-glass `publish.sh` force-pushes
  of develop).
- `lineage/sync-base-**`: require 1 approval + the `lineage/verify`
  status check, so the merge button only activates after review and
  a green verify. `sync.sh --push` posts that status after running
  the 7 sync acceptance checks locally.

Use org-level rulesets so one definition covers the fleet.

### Etiquette (the Renovate rules, reimplemented)

- **Never clobber a human.** Before force-pushing `lineage/sync`,
  compare the remote tip against the SHA recorded at last push
  (`.git/SYNC_PUSHED` locally, `<!-- lineage-sync:pushed-sha=… -->`
  marker in the PR body). Foreign commits ⇒ stop and say so instead
  of pushing.
- **One stable branch name, one open PR.** Refresh updates the
  existing PR (retargeting its base to a fresh decoy when develop
  moved) rather than opening siblings.
- **The Files tab is the review artifact.** The proxy head makes
  GitHub's native review surface show exactly the sync delta (inline
  comments, viewed checkboxes — the standard process). The published
  commits with their real authorship live on `lineage/sync`; the body
  carries the `git log` command for reviewers who want them.

## Scope and coexistence

- **Skeleton→skeleton layer only.** cisagov owns both ends; publish
  on approval is the right cadence. Project repos with outside
  contributors keep the controlled-points model (runbook §8) and do
  **not** get merge-to-publish — an immediate-publish button is the
  wrong affordance there.
- **action-lineage must stand down first** (future-work #1): the
  hourly bot opens *merge* PRs and would re-braid a linearized repo
  within the hour. Per-repo `strategy: rebase` in `lineage.yml`
  (ignored-unknown-key compatible today) is the handoff flag.
- **Break-glass:** `sync.sh --push` to develop directly is not a
  thing; the interactive path for emergencies is `publish.sh`-style
  operator force-push by someone on the bypass team, documented in
  runbook §8.
- **Packaging:** all of this is `gh skeleton sync` once folded into
  the extension (future-work #2); the extension vendors `scripts/`
  as-is.
- **Automation is phase 2.** The end state is a sync bot: the same
  `sync.sh` engine run by a scheduled job with an App-held signing
  key, auto-resolving from the shared rr-cache, opening/refreshing
  the PR itself; a human is needed only at a NEW conflict shape
  (exit 2 — those always need judgment, and the resolution is cached
  for the fleet). Operator-driven runs come first so the pilot has
  eyes on every step; nothing in the design changes when the driver
  becomes a bot.

## Failure modes

| Event | Outcome |
|---|---|
| Feature PR merges into develop mid-review | Publish lease fails; workflow comments; re-run `sync.sh` (new decoy, retargeted PR) |
| Human pushes to `lineage/sync` | Next `--push` refuses (marker mismatch); coordinate or delete the branch |
| Human pushes to `lineage/sync-review` | Machine-owned: overwritten on every refresh (the body says so); nothing can be published from it anyway — only tree-verified `lineage/sync` is |
| Sync branch refreshed after review (proxy stale) | Publish refuses: reviewed proxy tree ≠ recorded `lineage/sync` tree; re-run `--push` for a fresh proxy + re-review |
| Someone clicks "Update branch" on the PR | Head gains a merge commit ⇒ `lineage/verify` is stale ⇒ required check blocks merge |
| PR retargeted to develop and merged | Develop's ruleset is the backstop (linear history rejects the braid); `no-upstream-merges.yml` is the CI tripwire |
| Workflow absent/broken at merge time | Merge hits only the decoy; nothing published; delete decoy, re-run `--push` |

## Setup checklist (per repo / org, once)

1. Create the publish GitHub App; install on skeleton repos; note the
   installation ID.
2. Import the two rulesets (`ci/rulesets/README.md`) with the app as
   develop bypass actor.
3. Create the `lineage-publish` environment with the app ID + key
   secrets.
4. Merge `ci/lineage-publish.yml` and `ci/no-upstream-merges.yml` to
   develop via a normal PR (the workflow must be on develop before
   the first decoy snapshot).
5. Flag the repo `strategy: rebase` in `lineage.yml`; confirm
   action-lineage skips it.
6. First cycle: `scripts/sync.sh <repo>` → `--push` → review → merge.
