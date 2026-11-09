# Lineage rework — prior-art research (2026-09-14)

The question (worklog §42): before redesigning the Lineage bot for
rebase-based syncs, has anyone solved "keep hundreds of
deliberately-diverged downstream repos in sync with an evolving
skeleton" better or differently since Lineage was written (~2020-21)?

Method: three parallel research passes — (1) the
template-instantiation-with-updates ecosystem, (2) fleet-sync /
git-native / rerere prior art, (3) a source-level analysis of
`cisagov/action-lineage` @ `e22756c` (2026-08-05). Fit criteria: 312
repos, downstream repos diverge deliberately, no templating
variables (skeletons merge as-is), GitHub PR workflow, team already
invested in linear history + shared rerere.

## 1. Verdict: nobody has solved it better

**No tool in the 2026 ecosystem reuses conflict resolutions.** Every
surveyed system recomputes conflicts on each sync (copier, cruft,
cherry-pick tools), avoids them by fiat (actions-template-sync's
`-X theirs`, projen's read-only generated files), or sidesteps them
by shipping transformations instead of diffs (nx migrate,
OpenRewrite, Gruntwork Patcher). Highlights:

- **actions-template-sync** (v2.6.0, 2026-09, active) is the
  mainstream community Lineage-equivalent — and its conflict story
  is *worse* for divergent repos: squash-pull with `-X theirs`
  (template silently wins) plus a `.templatesyncignore` file.
- **copier** (v9.18.2, 2026-09) has the best-engineered update
  algorithm (regenerate old + new, re-apply local diff) but assumes
  template-owned generation with an answers file, and re-presents
  the same conflicts every cycle. **cruft** is unmaintained
  (last release 2024-12); copier won that niche.
- **GitHub native template repos**: still no update/sync story at
  all as of 2026. **Backstage**: golden-path drift remains an open
  problem with no first-party answer.
- Two tools independently converged on our direction —
  **coopTilleuls/template-sync** (squash + cherry-pick; dormant
  since 2024) and **regraft** (v1.0.0, 2026-09-08: replays template
  commits by cherry-pick with a `Regraft-source: <sha>` provenance
  trailer on each; 0 stars, embryonic). Validation, not candidates.

## 2. Shared rerere: validated, and our shape is novel

Real prior art exists — all in single-fork↔single-upstream
recurring-sync contexts, never fleet-wide:

- **multipath-tcp/mptcp-upstream-rr-cache** — kernel subsystem team
  shares an rr-cache repo for syncs against net/net-next; active
  through 2026-06.
- **qualcomm-linux/automerge** — documented team workflow: point the
  merge harness at a remote rr-cache repo, resolve once, commit the
  cache back; CI and teammates replay. The cisagov pattern, exactly.
- **perl11/cperl-git-rr-cache** (535 commits, submodule-mounted) and
  **TiVo/androidx-rerere-cache** — same idea, smaller.
- **git-bpf** (2012, abandoned): the only generalized team-rerere
  tool ever published (rr-cache-as-branch + hook sync). No successor.

**Nobody has published the N-sibling amplification** — one cache
spanning hundreds of repos whose conflicts against a common ancestor
are textually identical. On the evidence, that is novel and
publishable.

**Counter-evidence to cite in the narrative** (the risks the design
was built against):

- **YugabyteDB** contributor docs mandate `rm -rf .git/rr-cache`
  before upstream merges: wrong resolutions replay silently, and
  auto-resolutions escape the documentation trail.
- **git-imerge** hard-disables rerere during its trial merges for
  the same reason.

Both objections are answered point-for-point by the harness: the
`archive/pre-linearization` empty-diff oracle + reconciliation
commit (silent-wrong-replay), and per-stop resolution logs
(documentation trail).

## 3. Genuinely different paradigms (and why we're not switching)

- **Codemod propagation** (nx migrate — now with AI-agentic hybrid
  steps; OpenRewrite/Moderne; Gruntwork Patcher; Spotify
  Fleetshift): the maintainer ships each change as a transformation
  re-derived against whatever the downstream looks like — no merge,
  no conflict. Wrong shape for carrying skeleton *history*, but the
  right complement for one-shot script-expressible changes
  (multi-gitter, v0.63.1 2026-05, is the healthy free fleet runner).
- **Ownership inversion** (projen, googleapis OwlBot→librarian):
  generated files are read-only / re-conformed on every PR;
  divergence is forbidden by construction. Philosophically opposite
  to cisagov's deliberate divergence; OwlBot itself is deprecated.
- **Runtime reference instead of vendoring** (Renovate presets,
  GitHub reusable/org-required workflows): shrink the synced surface
  — files that become references need no sync at all. Complementary.
- **Patch-stack school** (quilt/stgit, Electron, Brave): divergence
  as a curated, justified patch stack replayed per upstream bump.
  Doesn't transfer directly (our divergence lives inside shared
  files), but the discipline does (see steal-list).
- **.NET VMR codeflow (Maestro/darc)**: two-way sync PRs between a
  virtual monorepo and ~30 repos, with conflict PRs as routine
  first-class events. Closest large-scale living relative;
  bespoke infrastructure.
- **Spotify fleet management**: 270k PRs/yr, 77% automerged with no
  repo-owner review (opt-out, working-hours-only, post-merge health
  correlation). Key inversion: the change author owns the merge
  decision; conflict risk is attacked by merging fast enough that
  divergence windows barely exist.

## 4. Ideas worth stealing for the rework

1. **mergiraf as merge driver** (mergiraf.org; active, healthy):
   tree-sitter structural merging auto-resolves YAML/config-class
   conflicts *before* rerere is consulted — fewer stops, smaller
   cache. Caveat to test first: the driver changes conflict text,
   i.e. rerere pre-images — never switch drivers mid-campaign.
2. **Provenance trailers** (regraft): stamp replayed commits with
   `Lineage-source: <sha>` — sync state lives in history, survives
   clones and rebases, replaces merge-topology archaeology.
3. **Auto-merge clean syncs** (Spotify): when a sync PR applied
   conflict-free (rerere hit or clean rebase) and checks pass, merge
   without downstream review — opt-out per repo, working-hours only.
   Directly attacks the stale-open-Lineage-PR compounding problem.
4. **Conflict PR as routine event** (.NET codeflow): on an
   unresolvable stop, open the PR anyway in draft with stop context
   attached (our `show-stop.sh` output is exactly that artifact).
5. **Drift check on downstream PRs** (OwlBot posture): flag edits to
   skeleton-owned files at birth instead of at next sync.
6. **Divergence justification discipline** (Electron): long-lived
   rerere entries should carry a why + intended lifetime;
   unjustified ones are candidates for upstreaming into the
   skeleton, permanently shrinking the conflict surface.
7. **AI-resolve-once + rerere-forever + oracle**: LLM at manual
   stops, the shared cache makes each accepted resolution permanent
   fleet-wide, the archive-diff oracle vetoes bad ones. No published
   precedent for the combination.

## 5. action-lineage current state (facts for requirements)

Source analysis @ `e22756c`, clone at /tmp/action-lineage-research:

- Python 3.10 Docker action; **one central org-wide scan** (hourly
  cron in action-lineage's own repo, `repo_query: org:cisagov
  archived:false`, running `@develop`, single PAT with push
  everywhere). Issue #78 (open, 2024) proposes per-repo redesign.
- Algorithm per repo: fetch lineage.yml raw → fresh clone → branch
  `lineage/<id>` → `git merge --no-commit FETCH_HEAD` → **on
  conflict, `git add .` stages the markers**, commit, plain push,
  draft "⚠️ CONFLICT!" PR instructing a human to redo the merge and
  force-push. lineage.yml is protected mid-merge by reset/checkout.
- lineage.yml schema: `version: "1"` + `lineage:` map of
  `{local-branch?, remote-url!, remote-branch? (default HEAD)}`.
  Unknown keys are ignored → downstreams can carry
  `strategy: rebase` today without breaking v3.0.1.
- **No strategy switch exists; no `--force` anywhere.** Clean
  dispatch point at the single `merge()` call; push site needs a
  force-with-lease variant; PR templates are package data with a
  loader that already takes custom filenames.
- **Force-push hazard**: after a skeleton force-push the bot either
  silently stalls ("unrelated histories" → warn + skip) or opens a
  giant conflict-marker draft PR in every downstream **within the
  hour**. Bot rework (or pause) must precede further tier-1
  publishes with children.
- Rerere wiring is easy: fresh clone per repo per run, full outbound
  network, image rebuilt per run — clone the cache once per scan,
  symlink into each repo, `rerere.enabled true`.
- Tests: effectively none for git/PR logic (two trivial unit tests);
  the real CI bar is the cisagov pre-commit wall + mypy. A rebase
  mode brings the first git integration tests.
- Maintainers: @dav3r @felddy @jsf9k @mcdonnnj. Releases ~2-4/yr;
  prod runs `@develop`.

## 6. Recommendation

Proceed with the rebase + shared-rerere Lineage rework — nothing
off-the-shelf replaces it, the shared-cache design has real (if
quiet) prior art in kernel-adjacent teams, and the published
objections to rerere are precisely the ones the harness already
answers. Fold in, at minimum: the `strategy:` per-repo flag,
rerere-cache fetch in the action, force-with-lease + rewritten-PR
handling, and provenance trailers; consider mergiraf and clean-sync
auto-merge as fast-follows; treat codemod-style fleet runners and
vendoring-reduction as complements outside the bot.
