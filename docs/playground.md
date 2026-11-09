# Playground — a day in the life of a lineage sync

Live rehearsal environment for the merge-to-publish flow
(`design.md`), in the **`dhs-ncats` sandbox org** (empty squatted
org; nothing of value; repos are clearly labeled SANDBOX). The repos
are seeded from the real public cisagov histories, so the conflicts
you'll hit are the real ones — including the 2024-10-30
`dependabot.yml` shape from `narrative.md`.

Everything here is driven by `scripts/playground.sh`, which can only
talk to the sandbox org (it refuses cisagov) and uses an **isolated
rr-cache** under `work/playground/` so demo resolutions never enter
the real shared cache.

**Team access:** clone the kit —
`gh repo clone dhs-ncats/lineage-playground` — and start at its
README (prerequisites: org write access, headless commit signing).
The kit carries these scripts and docs; the rerere harness tree
remains the source of truth, republished with `playground.sh kit`.
You need write access to the `dhs-ncats` repos to push syncs and
merge PRs — ask Mark. **One driver at a time**: the sandbox repos are
shared state, so `reset` at the start of a session and say so in the
team channel.

```bash
scripts/playground.sh setup      # once: create + seed the repos
scripts/playground.sh reset      # anytime: back to the starting line
scripts/playground.sh status     # where things stand
```

Roles for a group run-through: **operator** (terminal), **reviewer**
(browser), **interloper** (browser or terminal). Swap freely.

---

## Scenario 1 — clean sync, end to end (~5 min)

```bash
scripts/playground.sh upstream clean       # parent gains a harmless commit
scripts/playground.sh sync                 # rebase + verify; zero stops
scripts/playground.sh sync --push --yes    # branch + decoy + PR + status
```

Reviewer: open the PR in `dhs-ncats/skeleton-action-composite`.
Notice: base is the decoy (`lineage/sync-base-<sha>`), the
`lineage/verify` status is green, the body explains itself and
carries the real review diff command. Approve, **merge**.

Watch the `lineage-publish` Actions run: it force-pushes the reviewed
SHA to develop with the lease, deletes the review branches, and
comments on the PR. `playground.sh status` confirms develop moved.

## Scenario 2 — conflicted sync: the human moment (~10 min)

```bash
scripts/playground.sh reset
scripts/playground.sh upstream conflict    # the 2024-10-30 dependabot shape
scripts/playground.sh sync                 # exits 2 at the NEW conflict
```

Operator: open the named file in `work/playground/<child>-sync/`,
resolve the markers (keep upstream's new ignore line AND the child's
uncommented block), then:

```bash
git -C work/playground/skeleton-action-composite-sync add .github/dependabot.yml
scripts/playground.sh sync --resume "note: kept upstream's upload-artifact line, child block stays uncommented"
scripts/playground.sh sync --push --yes
```

Reviewer: the PR body's resolution-log line shows the stop and your
note; the review diff shows exactly the upstream change + your
resolution. Approve, merge, watch it publish.

## Scenario 3 — temporal reuse: the aha moment (~3 min)

```bash
scripts/playground.sh reset                # repos to baseline; CACHE kept
scripts/playground.sh upstream conflict    # the SAME change again
scripts/playground.sh sync                 # completes: rerere resolved it
```

Same conflict, zero human input — `stops=1 rerere=1 manual=0` in the
output. This is the whole premise: scenario 2's resolution was
recorded once and replays forever (fleet-wide, via the shared cache,
in production).

## Scenario 4 — the interloper: lease protection (~5 min)

```bash
scripts/playground.sh reset
scripts/playground.sh upstream clean
scripts/playground.sh sync && scripts/playground.sh sync --push --yes
scripts/playground.sh interloper           # feature commit reaches develop mid-review
```

Reviewer: merge the sync PR anyway. The publish run **fails the
lease**, comments on the PR that nothing was overwritten, and develop
still has the interloper's commit. Recover exactly as the comment
says: `playground.sh sync --fresh`, push, fresh PR.

## Scenario 5 — the hand edit: no-clobber (~3 min)

```bash
scripts/playground.sh reset
scripts/playground.sh upstream clean
scripts/playground.sh sync && scripts/playground.sh sync --push --yes
scripts/playground.sh meddle               # human commit on origin/lineage/sync
scripts/playground.sh sync --fresh && scripts/playground.sh sync --push --yes   # ← refuses
```

The push refuses with the marker mismatch message; the human's commit
survives. That's the Renovate etiquette, reimplemented.

---

## What to evaluate while playing (for the review-process question)

The open design question is the **review surface**: in the current
variant the PR's Files tab shows the replayed downstream stack (diff
vs the upstream snapshot), and the true sync delta is a command in
the body — inline comments on the real change aren't possible. A
**review-proxy variant** (PR head = one generated commit whose tree
is byte-identical to the sync result, based on the develop snapshot)
would put exactly the sync delta in the Files tab, with normal inline
review; the workflow would verify tree-equality before publishing.
Run scenario 2 and judge the current variant's review experience —
if it confirms the non-starter, the proxy variant is the planned
follow-up and this playground is where it gets A/B'd.

## Housekeeping

- Sandbox-mode publish: the workflow falls back to `GITHUB_TOKEN`
  when the App secrets are absent — works here because sandbox
  develop is unprotected. Adding the real App + rulesets to the
  sandbox is the next fidelity step (team-decisions #1/#4).
- `reset` keeps the playground rr-cache (scenario 3 depends on it);
  `reset --full` wipes it. Closed PRs accumulate — cosmetic.
- `playground.sh nuke` deletes the repos (token needs the
  `delete_repo` scope).
