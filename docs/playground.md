# Playground — a day in the life of a lineage sync

Live rehearsal environment for the merge-to-publish flow
(`design.md`), in the **`dhs-ncats` sandbox org** (empty squatted
org; repos are clearly labeled SANDBOX). The sandbox models the real
**two-tier lineage**:

```
sandbox-skeleton-generic → sandbox-skeleton-ansible-role → sandbox-ansible-role-banner
        (root)                      (tier 1)                      (tier 2)
```

seeded from the real public cisagov histories at **coherent pins**
(the role at its current tip; the skeleton at the commit the role is
caught up with; generic at the commit that skeleton state is caught
up with), then linearized tier-by-tier during setup — tier 2
exercises `linearize.sh`'s archive-tag invariant, the same path the
real campaign uses after a parent publishes. The conflicts you hit
here are real cisagov conflict shapes.

Syncs are driven through the **gh extension** (below); the sandbox
itself — seeding, resets, upstream changes, interloper/meddle
mischief — is driven by `scripts/playground.sh`, which can only talk
to the sandbox org (it refuses cisagov) and uses an **isolated
scenario rr-cache** under `work/playground/` so demo resolutions
never enter the real shared cache.

Sandbox repos are always **`sandbox-` prefixed**: `dhs-ncats` is
cisagov's pre-rename org name, so bare historical repo names there
carry GitHub rename redirects into cisagov — creating one hijacks the
redirect, pushing through one writes to the real org. The driver
verifies every name resolves inside the sandbox before touching it.

**Maximum fidelity — the gh extension:** `dhs-ncats/gh-skeleton` is
the real cisagov extension's history with the lineage subcommands
committed on top (`gh skeleton sync|linearize|verify|verify-sync|
publish|cache|stop|smoke`, dispatching into the vendored harness).
Install it to drive scenarios the way the final tool will work (gh
allows one extension per name, so temporarily swap the cisagov one
out — the kit README has the exact commands). **Caveat: the
extension's default org is `cisagov`, on purpose** — run bare it
reads real repos (pushes stay human-gated); for sandbox use always
`source ./sandbox-env` in the kit first, which points it at the
sandbox and keeps its rr-cache isolated. Whether the default becomes
a flag (like `clone`'s `--src-org`) is an open question for the
upstream PR. The future upstream PR is literally the sandbox repo's
commits above cisagov's history.

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
source ./sandbox-env             # every session: point the extension
                                 #   at the sandbox (NOT cisagov)
scripts/playground.sh setup      # once (slow: linearizes both tiers)
scripts/playground.sh reset      # anytime: back to the starting line
scripts/playground.sh status     # where things stand
```

The scenarios below drive syncs through the **extension** — install
it per the README first. Sandbox manipulation (`setup`, `reset`,
`upstream`, `interloper`, `meddle`, `status`) is always
`scripts/playground.sh`; it exists only for the sandbox. No extension
installed? Every `gh skeleton sync …` line has a playground
shorthand: `scripts/playground.sh sync skel|role [same args]` (the
tier keyword replaces the repo + `--parent` pair).

Roles for a group run-through: **operator** (terminal), **reviewer**
(browser), **interloper** (browser or terminal). Swap freely.

---

## Scenario 1 — clean sync, end to end (~5 min)

```bash
scripts/playground.sh upstream clean        # generic gains a harmless commit
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
```

Reviewer: open the PR in `dhs-ncats/sandbox-skeleton-ansible-role`.
Notice: the **Files tab shows exactly the sync delta** (here: two
lines in `.pre-commit-config.yaml`) — the head is a generated review
proxy whose tree is byte-identical to the real rebased branch; the
base is the decoy (`lineage/sync-base-<sha>`); `lineage/verify` is
green. Review it like any PR. Approve, **merge**.

Watch the `lineage-publish` Actions run: it force-pushes the reviewed
SHA to develop with the lease, deletes the review branches, and
comments on the PR. `playground.sh status` confirms develop moved.

## Scenario 2 — the cascade: two tiers, real world (~10 min)

The payoff scenario. After scenario 1 published the skeleton, the
*role* is now behind **its** upstream:

```bash
# upstream = the skeleton's freshly published develop
gh skeleton sync --parent sandbox-skeleton-ansible-role sandbox-ansible-role-banner
gh skeleton sync --push --yes --parent sandbox-skeleton-ansible-role sandbox-ansible-role-banner
```

Review and merge in `dhs-ncats/sandbox-ansible-role-banner` — same flow, one
tier down. This is the steady state for the whole fleet: a
skeleton-generic change propagates by one sync+review+merge per tier,
each publish feeding the next tier's upstream.

## Scenario 3 — conflicted sync: the human moment (~10 min)

```bash
scripts/playground.sh reset
scripts/playground.sh upstream conflict     # the dependabot ignore-block shape
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role   # exits 2
```

Both tiers customize that region in real life (the skeleton
uncomments generic's ignore block; the role uncomments the skeleton's
sub-entries), so expect the skeleton to pause (exit 2) at a NEW
conflict shape — and the role possibly again on the cascade, with its
own shape. Operator: open the named file in
`work/playground/<repo>-sync/`, resolve the markers (keep upstream's
new line AND the downstream customization), then:

```bash
git -C work/playground/<repo>-sync add .github/dependabot.yml
gh skeleton sync --resume --parent <parent> <repo> "note: kept upstream's upload-artifact line + our customization"
gh skeleton sync --push --yes --parent <parent> <repo>
```

Reviewer: the PR body's resolution-log line shows the stop and your
note; the review diff shows exactly the upstream change + your
resolution. Approve, merge, watch it publish.

## Scenario 4 — temporal reuse: the aha moment (~3 min)

```bash
scripts/playground.sh reset                 # repos to baseline; CACHE kept
scripts/playground.sh upstream conflict     # the SAME change again
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role   # completes: rerere resolved it
```

Same conflict, zero human input — `manual=0` in the totals. This is
the premise: scenario 3's resolution was recorded once and replays
forever (fleet-wide, via the shared cache, in production).

## Scenario 5 — the interloper: lease protection (~5 min)

```bash
scripts/playground.sh reset
scripts/playground.sh upstream clean
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
scripts/playground.sh interloper skel       # feature commit reaches develop mid-review
```

Reviewer: merge the sync PR anyway. The publish run **fails the
lease**, comments on the PR that nothing was overwritten, and develop
still has the interloper's commit. Recover exactly as the comment
says: `playground.sh sync skel --fresh`, push, fresh PR.

## Scenario 6 — the hand edit: no-clobber (~3 min)

```bash
scripts/playground.sh reset
scripts/playground.sh upstream clean
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
scripts/playground.sh meddle skel           # human commit on origin/lineage/sync
gh skeleton sync --fresh --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role   # ← refuses
```

The push refuses with the marker mismatch message; the human's commit
survives. That's the Renovate etiquette, reimplemented.

---

## The review surface

The PR head is a **review proxy**: one generated commit, parented on
the develop snapshot, whose tree is byte-identical to the real
rebased branch — so the Files tab shows exactly the sync delta and
the standard review process (inline comments, viewed checkboxes)
applies to the real change. Publish refuses unless the reviewed tree
equals `lineage/sync`, and what reaches develop is that branch's
real, signed, per-commit history. (Adopted 2026-11-12 after the team
hit the alternative's Files tab showing the whole replayed downstream
stack; worklog §49.)

## Housekeeping

- Sandbox-mode publish: the workflow falls back to `GITHUB_TOKEN`
  when the App secrets are absent — works here because sandbox
  develop only carries a linear-history ruleset (which the publish
  force-push satisfies). Adding the real App + full rulesets is the
  next fidelity step (team-decisions #1/#4).
- The seeded linear histories are **unsigned** (sandbox seeds don't
  depend on a primed signing agent); every scenario sync re-signs
  what it replays with *your* key, which is why headless signing is a
  prerequisite.
- Setup disables the repos' inherited CI (molecule, CodeQL, build) so
  it can't hog the runner queue ahead of `lineage-publish`; only the
  two lineage workflows stay active.
- `reset` keeps the scenario rr-cache (scenario 4 depends on it);
  `reset --full` wipes it. Closed PRs accumulate — cosmetic.
- `playground.sh nuke` deletes the repos (token needs the
  `delete_repo` scope).
