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

**What this models:** the routine fleet event. The root skeleton
merges an ordinary improvement that touches nothing this downstream
repo customized, and the change propagates with one sync, one review,
one merge. This is what ~95% of real syncs look like.

```bash
# Scripted stand-in for "a PR merged on the root skeleton": pushes a
# harmless two-line commit to sandbox-skeleton-generic's develop.
scripts/playground.sh upstream clean

# The sync: fresh-clones the skeleton into work/playground/, fetches
# its parent, and rebases ONLY this repo's own commits (from the
# recorded lineage/base tag) onto the new upstream tip, with rerere
# armed. Ends by running the 7 acceptance checks — ancestry,
# linearity, no conflict markers, a merge-oracle tree comparison,
# commit accounting, signatures, freshness.
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role

# The push: publishes the three REVIEW refs and opens the PR.
#   lineage/sync         = the real rebased history (signed, per-commit)
#   lineage/sync-review  = the PR head: ONE generated commit whose tree
#                          is byte-identical to lineage/sync — what the
#                          Files tab diffs
#   lineage/sync-base-*  = the PR base: a snapshot of develop, which is
#                          also the publish lease value
# Then posts the green `lineage/verify` status on the head.
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
```

**Reviewer** (browser): open the PR in
`dhs-ncats/sandbox-skeleton-ansible-role`. The **Files tab shows
exactly the sync delta** — here, two lines in
`.pre-commit-config.yaml`. Review it like any PR (inline comments
work; they're on the real change). Approve, **merge**. Merging is the
publish trigger: nothing reaches develop until this click.

**What you should see:** the sync prints `rebase completed with zero
stops` and `result: 7 passed`; the PR is 1 file / +2 / 1 commit; after
merge, the `lineage-publish` Actions run verifies the reviewed tree
equals `lineage/sync`, force-pushes **that branch** to develop with
the lease, deletes all three review branches, and comments on the PR.
`playground.sh status` confirms develop moved to the new SHA.

## Scenario 2 — the cascade: two tiers, real world (~10 min)

**What this models:** propagation down the lineage. Scenario 1's
publish *rewrote the skeleton's history* (every commit above generic
got a new SHA — that's inherent to rebase-publishing), so the role is
now behind its upstream. The role doesn't care about the rewrite: its
`lineage/base` tag records exactly which parent tip it last synced
onto, so the sync replays only the role's own ~30 commits, not the
skeleton's ~160 it inherits.

```bash
# No playground step needed — scenario 1's publish IS the upstream
# change, one tier down. Same two commands, different repo/parent:
gh skeleton sync --parent sandbox-skeleton-ansible-role sandbox-ansible-role-banner
gh skeleton sync --push --yes --parent sandbox-skeleton-ansible-role sandbox-ansible-role-banner
```

Review and merge in `dhs-ncats/sandbox-ansible-role-banner` — the
identical flow, one tier down. This is the fleet's steady state: a
skeleton-generic change propagates by one sync+review+merge per tier,
each publish feeding the next tier's upstream and re-recording its
`lineage/base`.

**What you should see:** the sync prints `lineage/base tag found … —
replaying only this repo's own delta` and a small replay count; verify
may report commits `absorbed upstream` (identical changes the parent
already carries get dropped — that's correct, and the merge oracle
confirms the tree).

## Scenario 3 — conflicted sync: the human moment (~10 min)

**What this models:** the one case that needs a person — upstream
edits a region this repo deliberately customized. The scripted change
is the real conflict from 2024-10-30: generic keeps its Dependabot
`ignore:` block commented out; downstreams *uncomment* it; generic
then adds a new entry inside that block. Same lines, two intentions —
a genuine conflict no tool should guess at.

```bash
scripts/playground.sh reset
scripts/playground.sh upstream conflict     # the byte-exact dependabot edit
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
```

The sync stops with **exit 2** at the first replayed commit touching
that region: `stop 1: NEW conflict shape — .github/dependabot.yml`.
"New shape" means the rerere cache has never seen this exact conflict
text. The work tree is left mid-rebase with ordinary git conflict
markers — resolve it the lineage way (keep upstream's new entry AND
the uncommented customization), stage it, and resume with a note:

```bash
$EDITOR work/playground/sandbox-skeleton-ansible-role-sync/.github/dependabot.yml
git -C work/playground/sandbox-skeleton-ansible-role-sync add .github/dependabot.yml
gh skeleton sync --resume --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role \
  "note: kept upstream's upload-artifact entry inside our uncommented block"
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
```

Two things happen at `--resume`: your note goes into the resolution
log (the reviewer's sign-off record, quoted in the PR body), and
**rerere records the resolution** into the scenario cache — that
recording is what scenario 4 demonstrates. Verify's merge oracle then
independently replays the resolution in a scratch merge and demands
the identical tree.

**What you should see:** the stop message naming commit and file;
after resume, `result: 7 passed` including the merge oracle; a PR
whose Files tab shows upstream's new entry merged into the
customized block — exactly what a reviewer should sign off on.

## Scenario 4 — temporal reuse: the aha moment (~3 min)

**What this models:** the project's core premise — a conflict is
resolved ONCE, ever. In production the recorded resolution replays
for every future sync and (via the shared cache) every sibling repo
and teammate hitting the same shape. Here, `reset` rewinds the
branches but deliberately **keeps the scenario cache**, so replaying
scenario 3's upstream change re-creates the exact conflict rerere
already knows.

```bash
scripts/playground.sh reset                 # branches to baseline; CACHE kept
scripts/playground.sh upstream conflict     # the SAME byte-exact change
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
```

**What you should see:** no pause this time — the same rebase that
stopped in scenario 3 runs to completion, and the totals line reads
`stops=1 · rerere=1 · manual=0`: the conflict occurred, rerere
recognized its fingerprint and applied the recorded resolution, no
human was consulted. Verify still passes 7/7 (the oracle re-checks
the content; reuse is never blind trust).

## Scenario 5 — the interloper: lease protection (~5 min)

**What this models:** a normal feature PR merging into develop while
a sync PR sits in review. Publishing *replaces* develop wholesale
(rebase model), so an unguarded publish would silently destroy that
feature commit. The guard is the lease: the publish workflow
force-pushes with `--force-with-lease` pinned to the develop snapshot
recorded at sync time — if develop is anything else, it refuses.

```bash
scripts/playground.sh reset
scripts/playground.sh upstream clean
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
scripts/playground.sh interloper skel       # pushes a commit straight to the
                                            # skeleton's develop — a stand-in
                                            # for a feature PR merged mid-review
```

**Reviewer:** merge the sync PR anyway, as if nobody noticed.

**What you should see:** the `lineage-publish` run **fails** at the
lease, comments on the PR that nothing was overwritten, and
`playground.sh status` shows develop still carrying the interloper's
commit. Recovery is exactly what the comment says: re-run the sync
(`gh skeleton sync --fresh …`) so it rebuilds on the new develop,
push, fresh PR.

## Scenario 6 — the hand edit: no-clobber (~3 min)

**What this models:** a well-meaning human pushes a commit onto the
bot-owned `lineage/sync` branch — it's an ordinary branch, nothing
stops them. The next push refresh would force-push right over their
work; instead, the push gate compares the remote tip against the SHA
it recorded at its own last push (a local file, plus a marker in the
PR body so any teammate's clone can recover it) and refuses on a
mismatch. That's the branch-ownership etiquette Renovate uses,
reimplemented.

```bash
scripts/playground.sh reset
scripts/playground.sh upstream clean
gh skeleton sync --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
scripts/playground.sh meddle skel           # the human's commit on origin/lineage/sync
gh skeleton sync --fresh --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role
gh skeleton sync --push --yes --parent sandbox-skeleton-generic sandbox-skeleton-ansible-role   # ← refuses
```

**What you should see:** the second `--push` dies with `origin/
lineage/sync has commits we didn't push … coordinate with them
instead of clobbering`, and the human's commit survives on the
branch. (Contrast: `lineage/sync-review` has the opposite contract —
machine-owned and overwritten on every refresh — which is why
resolutions always happen on `lineage/sync`, never on the proxy.)

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
