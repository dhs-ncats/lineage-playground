# Merge-to-publish rollout — decisions needed from the team

Context for the meeting: the rebase-sync harness is built and
smoke-tested (`design.md`, worklog §43). Deploying it needs the
org-side pieces below. Each item has a recommendation so this can be
a yes/no pass; the one real workflow change for everyone is **#6**.

## 1. The publish App

An org-owned GitHub App performs the leased force-push to develop
when a lineage sync PR is merged. Decide: name (suggest
`lineage-publish`), who creates and administers it, and key custody.
Permissions needed: contents write + pull-requests write, installed
only on linearized skeleton repos.
**Recommendation:** org-owned; private key lives ONLY in each repo's
`lineage-publish` environment secrets; rotation owner named now.

## 2. The operators team (bypass actor)

Break-glass force-push of develop (`publish.sh`, runbook §8) and the
decoy-creation fallback require a team listed as ruleset bypass.
Decide: new `lineage-operators` team vs. an existing one, and its
membership. Bypass use is logged in ruleset insights.
**Recommendation:** a new, small, purpose-named team.

## 3. Environment protection on `lineage-publish`

Required reviewers on the environment would add a second human gate
on every publish, at the cost of one more approval click per sync.
**Recommendation:** start without; the decoy ruleset's PR approval is
the gate. Revisit after the pilot if the credential's blast radius
worries anyone.

## 4. Org-level vs per-repo rulesets

One org ruleset per file (`ci/rulesets/`) covers the fleet but needs
repository targeting; per-repo imports are more moving parts as the
campaign publishes more skeletons.
**Recommendation:** org rulesets targeting a custom repository
property (e.g. `linearized=true`), set per repo at publish time.

## 5. Decoy-gate review policy

`required_approving_review_count` on the sync PR: 1 (current default)
or 2 if org convention demands. Keep `require_last_push_approval`?
Who reviews lineage PRs — repo owner, CODEOWNERS, any operator?
**Recommendation:** 1 approval + last-push approval, reviewer = the
repo's tracker owner.

## 6. develop ruleset: keep develop linear ← the daily-workflow change

Two commit streams reach develop on a linearized repo, and this item
is only about the second:

- **Lineage syncs** — pure rebase. The sync PR's merge button merges
  into the throwaway decoy; develop receives the rebased history via
  the leased force-push. No merge or squash commit from a sync ever
  touches develop.
- **Ordinary PRs** (features, dependabot) — unchanged by this whole
  design: they merge into develop with GitHub's normal button
  between syncs.

The proposed develop ruleset adds `required_linear_history`, which
removes only the "Create a merge commit" option from ordinary PRs —
"Rebase and merge" and "Squash and merge" both remain. A merge commit
on develop is exactly the braid the campaign removes, and the CI
tripwire only catches upstream-sourced merges; this closes the rest.

Signing: **not enforced by ruleset.** cisagov does not require signed
commits org-wide, and `required_signatures` would impose it on every
contributor (and block rebase-merges, which GitHub leaves unsigned).
The project's signing policy (worklog §31) is narrower and stays
harness-side: whoever force-pushes rewritten history signs it
(`publish.sh` / `verify-sync.sh` refuse otherwise) — contributors
never touch it. Bonus: each sync replays every commit above upstream,
signed by the sync operator, so signed coverage of develop grows on
its own with zero contributor burden.

Decide: is losing the merge-commit button on linearized repos
acceptable?
**Recommendation:** yes — it is the ref-level form of the linear
model; both remaining merge methods keep daily work otherwise
unchanged.

## 7. action-lineage stand-down (the blocker)

The hourly bot merge-syncs everything; a published skeleton with
children gets re-braided within the hour. Decide: approve the
minimal change — the bot **skips** repos whose `lineage.yml` carries
`strategy: rebase` (the key is ignored harmlessly today, so flagging
can precede the bot release) — and name an owner for that PR and its
release. Confirm: **no skeleton with children publishes until this
is deployed** (tier-1 publishing is otherwise ready: six repos
linearized, verified, waiting).
**Recommendation:** skip-flag PR only; teaching the bot to rebase
itself is not needed — the harness/extension owns rebasing.

Keep this distinct from the **future sync bot**: the end state is
still an app/bot that rebases and signs — that is `sync.sh` run by a
scheduled job with an App-held signing key, auto-resolving from the
shared rr-cache, with a human pulled in only at a NEW conflict shape
(exit 2; those always need judgment). The pilot runs operator-driven
first; automation is phase 2 (see #9), not a different design. This
item is only about switching the OLD merge bot off per repo.

## 8. Pilot and rehearsal venue

Confirm `skeleton-action-composite` as pilot (published 2026-09-04,
Mark's, minimal blast radius). The rehearsal venue is settled: the
**`dhs-ncats` sandbox org** is live (2026-11-05) with both repos
seeded from the real cisagov histories, and the publish workflow has
executed there end-to-end — see `playground.md` for the run-through
the team can drive themselves. Remaining decision: confirm the pilot
repo and when to deploy there (with `ci/no-upstream-merges.yml`,
still pending from the September publish).

## 9. Sync operations & cadence

Who runs `sync.sh` (later `gh skeleton sync`) per repo, and when —
on upstream change, weekly, or batched? Manual per-operator is the
designed starting point.
**Recommendation:** tracker owner runs it when skeleton-generic
changes; phase 2 is the same engine on a schedule with an App-held
signing key (see #7), once the pilot has proven the flow.

## 10. Downstream notifications (future-work #6)

Publishing the six tier-1 skeletons rewrites develop SHAs for ~160
direct children's upstreams. Decide the channel and owner for the
"pull --rebase, not pull, on <date>" notice; recipients come from
`campaign/downstream-inventory.json`.

## 11. Scope ratification

Merge-to-publish applies to the **skeleton→skeleton layer only**;
project repos with outside contributors keep the controlled-points
model (runbook §8). Ratify as policy so it's written down, not habit.