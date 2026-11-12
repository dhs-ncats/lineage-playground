#!/usr/bin/env bash
# playground.sh — sandbox driver for rehearsing the merge-to-publish
# sync flow on real GitHub (lineage-rework/playground.md is the
# day-in-the-life script). Targets the SANDBOX org only and refuses
# cisagov outright; this is the one script allowed to push without a
# prompt, because it can only ever touch $PG_ORG.
#
# The sandbox models the real two-tier lineage (sandbox- prefixed —
# bare names in a renamed org shadow GitHub rename redirects; see the
# naming block below):
#   sandbox-skeleton-generic → sandbox-skeleton-ansible-role
#     → sandbox-ansible-role-banner
# seeded from the real (public) cisagov histories at COHERENT PINS:
# the role at its current tip, the skeleton at the commit the role is
# caught up with, generic at the commit that skeleton state is caught
# up with — so every §4a invariant holds by construction and setup
# can linearize both tiers unattended (tier 2 exercises the
# archive-tag invariant in linearize.sh). Seed linearizations run
# UNSIGNED (scenario syncs re-sign everything they replay; the
# signing policy covers real publishes, not sandbox seeds).
#
# Usage: scripts/playground.sh <verb> [args]
#
# Verbs:
#   setup              create + seed + linearize + sandbox-publish the
#                      three repos; baseline tags; isolated scenario
#                      rr-cache. Idempotent: done repos are skipped.
#                      SLOW on first run (two real linearizations).
#   reset              force all three repos back to baseline, delete
#                      lineage/* branches, close open PRs, wipe the
#                      playground work trees (the scenario CACHE
#                      survives — that's the temporal-reuse demo;
#                      `reset --full` wipes it too)
#   upstream clean     generic change that cannot conflict
#   upstream conflict  generic edit inside the dependabot.yml ignore
#                      block downstreams customize — byte-stable so
#                      rerere reuse is demonstrable after reset
#   sync skel|role …   run sync.sh for that tier with the playground
#                      env; extra args pass through (`--push --yes`,
#                      `--resume "note"`, `--fresh`)
#   interloper skel|role   push a commit straight to that repo's
#                      develop (a "feature PR merged mid-review") —
#                      sets up the lease-refusal demo
#   meddle skel|role   push a human commit onto that repo's
#                      origin/lineage/sync — sets up the no-clobber
#                      demo
#   ext                publish/update the gh EXTENSION in the sandbox
#                      ($PG_ORG/gh-skeleton): real upstream history +
#                      our lineage subcommands and vendored harness
#                      committed on top (the future cisagov PR shape).
#                      Install: gh extension install $PG_ORG/gh-skeleton
#   kit                publish/update the TEAM kit repo
#                      ($PG_ORG/lineage-playground); maintainer-run,
#                      this tree stays the source of truth
#   status             branches, open PRs, latest workflow runs
#   nuke               delete the sandbox repos (needs the
#                      delete_repo token scope)
#
# Env overrides: PG_ORG (default dhs-ncats), SEED_ORG (default
# cisagov — read-only source of truth), PG_ROOT/PG_SKEL/PG_ROLE and
# their PIN_* SHAs, KIT_REPO (default lineage-playground).

source "$(dirname "$0")/common.sh"

PG_ORG=${PG_ORG:-dhs-ncats}
SEED_ORG=${SEED_ORG:-cisagov}
# Source (cisagov) names and their sandbox counterparts. Sandbox names
# are ALWAYS sandbox- prefixed: dhs-ncats is cisagov's pre-rename org
# name, so bare historical repo names there carry GitHub rename
# redirects INTO cisagov — creating over one hijacks the redirect, and
# pushing through one writes to the real org. Never use bare names.
SRC_ROOT=${SRC_ROOT:-skeleton-generic}
SRC_SKEL=${SRC_SKEL:-skeleton-ansible-role}
SRC_ROLE=${SRC_ROLE:-ansible-role-banner}
PG_ROOT="sandbox-$SRC_ROOT"
PG_SKEL="sandbox-$SRC_SKEL"
PG_ROLE="sandbox-$SRC_ROLE"
# coherent snapshot pins (computed 2026-11-12; see playground.md)
PIN_ROOT=${PIN_ROOT:-5103fb6cb5a29a8127773f2e1c855352ab5be0f7}
PIN_SKEL=${PIN_SKEL:-e6776413b43c2ee271f77577d471fdccca048f94}
PIN_ROLE=${PIN_ROLE:-872389f8fdb7a1eedc071d96fa6f6ddce34e8b87}
KIT_REPO=${KIT_REPO:-lineage-playground}
PG_WORK="$ROOT/work/playground"
PG_CACHE="$PG_WORK/cache"
PG_URL="https://github.com/$PG_ORG"

# The whole point of this script is that it CANNOT touch the real org.
[[ "$PG_ORG" == *cisagov* ]] && die "PG_ORG=$PG_ORG — playground.sh refuses to operate on cisagov"
command -v gh >/dev/null || die "playground.sh needs gh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# seed linearizations must not depend on a primed signing agent
UNSIGNED=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false)

# Redirect-proof existence check: gh follows GitHub rename redirects,
# so "exists" must mean "resolves to EXACTLY $PG_ORG/$1". (On a 404,
# gh api exits non-zero but still prints the error body to stdout —
# always gate on the exit code, not the output.)
repo_exists() {
  local resolved
  resolved=$(gh api "repos/$PG_ORG/$1" --jq .full_name 2>/dev/null) || return 1
  [[ "$resolved" == "$PG_ORG/$1" ]]
}

# refuse to touch a name that resolves elsewhere (a rename redirect);
# a 404 is fine — the name is simply free
assert_sandbox() {
  local resolved
  resolved=$(gh api "repos/$PG_ORG/$1" --jq .full_name 2>/dev/null) || return 0
  [[ "$resolved" == "$PG_ORG/$1" ]] \
    || die "$PG_ORG/$1 resolves to $resolved (rename redirect) — refusing to touch it"
}

# fresh throwaway clone of a SANDBOX repo; echoes its path
pg_clone() {
  local dir="$TMP/$1.$RANDOM"
  git clone -q "$PG_URL/$1.git" "$dir"
  echo "$dir"
}

parent_of_tier() { # skel|role → repo + parent names on stdout
  case "$1" in
    skel) echo "$PG_SKEL $PG_ROOT";;
    role) echo "$PG_ROLE $PG_SKEL";;
    *)    die "unknown tier: $1 (skel|role)";;
  esac
}

# Add the sync workflows as an ORDINARY post-publish commit. Never in
# the pre-linearization seed: anything above the pin desyncs the next
# tier from the archive tag (its §4a gate correctly refuses). The
# commit is byte-identical in every repo, so a downstream's copy is
# dropped as already-applied on its first cascade sync. lineage.yml
# stays untouched (real cisagov URLs; the playground always passes
# --parent explicitly).
add_workflows() {
  local name=$1 c
  assert_sandbox "$name"
  c=$(pg_clone "$name")
  if [[ -f "$c/.github/workflows/lineage-publish.yml" ]]; then
    say "$name: workflows already present"
    return
  fi
  cp "$ROOT/ci/lineage-publish.yml" "$ROOT/ci/no-upstream-merges.yml" "$c/.github/workflows/"
  git -C "$c" add .github/workflows
  env "${UNSIGNED[@]}" git -C "$c" commit -q -m "Add lineage sync workflows"
  git -C "$c" push -q origin develop
  say "$name: workflows added on develop"
}

seed_repo() { # seed_repo NAME SRC PIN — develop = exactly the pin
  local name=$1 src_name=$2 pin=$3
  assert_sandbox "$name"
  if repo_exists "$name"; then
    say "$PG_ORG/$name already exists — leaving it alone"
    return
  fi
  say "creating $PG_ORG/$name (seed: $SEED_ORG/$src_name @ ${pin:0:12})"
  gh repo create "$PG_ORG/$name" --public \
    --description "SANDBOX — lineage merge-to-publish rehearsal ($SEED_ORG/$src_name stand-in); safe to delete" >/dev/null
  # creation must have produced OUR repo, not shadowed a redirect
  repo_exists "$name" || die "$PG_ORG/$name did not resolve canonically after creation"
  local src="$TMP/seed-$name"
  git clone -q "https://github.com/$SEED_ORG/$src_name.git" "$src"
  git -C "$src" remote add sandbox "$PG_URL/$name.git"
  git -C "$src" push -q sandbox "$pin:refs/heads/develop"
  gh api -X PATCH "repos/$PG_ORG/$name" -f default_branch=develop >/dev/null
}

# a pre-existing repo that has NOT been linearized yet (no archive tag
# on the remote) must sit exactly at its pin; re-pin drifted ones
# (e.g. carried over from an earlier playground era)
ensure_seed_state() { # ensure_seed_state NAME SRC PIN
  local name=$1 src_name=$2 pin=$3 tip c
  git ls-remote --tags "$PG_URL/$name.git" | grep -q 'archive/pre-linearization' && return
  tip=$(git ls-remote "$PG_URL/$name.git" refs/heads/develop | cut -f1)
  [[ "$tip" == "$pin" ]] && return
  c=$(pg_clone "$name")
  git -C "$c" cat-file -e "$pin^{commit}" 2>/dev/null \
    || git -C "$c" fetch -q "https://github.com/$SEED_ORG/$src_name.git" develop
  # drift ABOVE the pin is legitimate scenario state (upstream clean/
  # conflict commits) — `reset` owns undoing that. Only repair a
  # develop that doesn't contain the pin at all (wrong-era seed).
  if git -C "$c" merge-base --is-ancestor "$pin" "$tip" 2>/dev/null; then
    return
  fi
  say "$name: develop @ ${tip:0:12} does not contain pin ${pin:0:12} — re-pinning"
  git -C "$c" push -qf origin "$pin:refs/heads/develop"
}

# linearize a sandbox repo against its sandbox parent and publish the
# result as its develop (+ archive tag) — the runbook §4→§8 flow,
# scripted for the sandbox. Skipped when the archive tag already
# exists on the remote (= already done). Uses the REAL shared cache
# (training real public history is legitimate campaign work); the
# scenario syncs use the isolated playground cache instead.
linearize_and_publish() {
  local name=$1 parent=$2
  assert_sandbox "$name"
  if git ls-remote --tags "$PG_URL/$name.git" | grep -q 'archive/pre-linearization'; then
    say "$name: archive tag on remote — already linearized+published, skipping"
    return
  fi
  say "$name: linearizing against $parent (sandbox) — this takes a while"
  rm -rf "${PG_WORK:?}/$name"
  env "${UNSIGNED[@]}" ORG_URL="$PG_URL" WORK_DIR="$PG_WORK" LOG_DIR="$PG_WORK/logs" \
    "$ROOT/scripts/linearize.sh" --final-force --parent "$parent" "$name" >/dev/null \
    || die "$name: linearize failed (log: $PG_WORK/logs/$name.log)"
  ORG_URL="$PG_URL" WORK_DIR="$PG_WORK" LOG_DIR="$PG_WORK/logs" \
    "$ROOT/scripts/verify-linearization.sh" "$name" \
    || die "$name: verify-linearization failed"
  git -C "$PG_WORK/$name" push -qf origin develop-linear:develop
  git -C "$PG_WORK/$name" push -qf origin archive/pre-linearization
  # record the parent tip this linearization sat on, so the repo's
  # FIRST cascade sync already replays only its own delta
  git -C "$PG_WORK/$name" push -qf origin \
    "$(git -C "$PG_WORK/$name" rev-parse upstream/develop):refs/tags/lineage/base"
  say "$name: sandbox-published linear develop + archive tag + lineage/base"
}

baseline() { # tag + push sandbox-baseline at each repo's develop
  local name c
  for name in "$PG_ROOT" "$PG_SKEL" "$PG_ROLE"; do
    assert_sandbox "$name"
    c=$(pg_clone "$name")
    git -C "$c" tag -f sandbox-baseline origin/develop
    git -C "$c" push -qf origin sandbox-baseline
    # snapshot lineage/base too: reset must restore BOTH, or the next
    # sync would rebase --onto a base from a rolled-back future
    if git -C "$c" rev-parse -q --verify 'refs/tags/lineage/base^{commit}' >/dev/null; then
      git -C "$c" tag -f sandbox-baseline-lineage-base 'lineage/base^{commit}'
      git -C "$c" push -qf origin sandbox-baseline-lineage-base
    fi
  done
  say "baseline tags set at current develop tips"
}

# the seeded repos inherit heavy CI (molecule, CodeQL, build) that
# hogs the org's shared runner queue and delays lineage-publish;
# disable everything except the two lineage workflows
quiet_ci() {
  local name id path
  for name in "$PG_ROOT" "$PG_SKEL" "$PG_ROLE"; do
    while read -r id path; do
      case "$path" in
        */lineage-publish.yml|*/no-upstream-merges.yml) ;;
        *) if gh api -X PUT "repos/$PG_ORG/$name/actions/workflows/$id/disable" >/dev/null 2>&1; then
             say "$name: disabled ${path##*/}"
           else
             warn "$name: could not disable ${path##*/} (dispatch-managed workflows refuse this)"
           fi;;
      esac
    done < <(gh api "repos/$PG_ORG/$name/actions/workflows?per_page=100" \
               --jq '.workflows[] | select(.state=="active") | "\(.id) \(.path)"' 2>/dev/null)
  done
  # a skipped/failed last iteration must not become the function's rc
  return 0
}

cmd_setup() {
  seed_repo "$PG_ROOT" "$SRC_ROOT" "$PIN_ROOT"
  seed_repo "$PG_SKEL" "$SRC_SKEL" "$PIN_SKEL"
  seed_repo "$PG_ROLE" "$SRC_ROLE" "$PIN_ROLE"
  ensure_seed_state "$PG_ROOT" "$SRC_ROOT" "$PIN_ROOT"
  ensure_seed_state "$PG_SKEL" "$SRC_SKEL" "$PIN_SKEL"
  ensure_seed_state "$PG_ROLE" "$SRC_ROLE" "$PIN_ROLE"
  linearize_and_publish "$PG_SKEL" "$PG_ROOT"
  linearize_and_publish "$PG_ROLE" "$PG_SKEL"
  add_workflows "$PG_SKEL"
  add_workflows "$PG_ROLE"
  quiet_ci
  baseline
  if [[ ! -d "$PG_CACHE/.git" ]]; then
    say "initialising ISOLATED scenario rr-cache (scenario resolutions stay out of the real shared cache)"
    mkdir -p "$PG_CACHE"
    CACHE_DIR="$PG_CACHE" CACHE_REMOTE="$PG_URL/rerere-cache.git" \
      "$ROOT/scripts/setup-shared-cache.sh" >/dev/null 2>&1
    [[ -d "$PG_CACHE/.git" ]] || die "playground cache init failed"
  fi
  say "setup done — scenarios: lineage-rework/playground.md"
}

cmd_reset() {
  local full=${1:-}
  local repo c
  for repo in "$PG_ROOT" "$PG_SKEL" "$PG_ROLE"; do
    repo_exists "$repo" || die "$PG_ORG/$repo missing — run setup first"
    c=$(pg_clone "$repo")
    git -C "$c" push -q -f origin sandbox-baseline:refs/heads/develop
    if git -C "$c" rev-parse -q --verify 'refs/tags/sandbox-baseline-lineage-base^{commit}' >/dev/null; then
      git -C "$c" push -q -f origin \
        'refs/tags/sandbox-baseline-lineage-base^{commit}:refs/tags/lineage/base' 2>/dev/null \
        || git -C "$c" push -q -f origin \
             "$(git -C "$c" rev-parse 'sandbox-baseline-lineage-base^{commit}'):refs/tags/lineage/base"
    fi
    while read -r _ ref; do
      [[ -n "$ref" ]] && git -C "$c" push -q origin ":$ref"
    done < <(git -C "$c" ls-remote --heads origin 'lineage/*')
    say "$repo: develop → baseline, lineage/* branches cleared"
  done
  for repo in "$PG_SKEL" "$PG_ROLE"; do
    while read -r n; do
      [[ -n "$n" ]] && gh pr close "$n" -R "$PG_ORG/$repo" -c "playground reset" >/dev/null \
        && say "closed $repo PR #$n"
    done < <(gh pr list -R "$PG_ORG/$repo" --state open --json number --jq '.[].number')
  done
  find "$PG_WORK" -mindepth 1 -maxdepth 1 ! -name cache ! -name logs -exec rm -rf {} +
  if [[ "$full" == "--full" ]]; then
    rm -rf "$PG_CACHE"
    say "scenario rr-cache wiped (--full)"
  else
    say "scenario rr-cache KEPT (temporal-reuse demo); use 'reset --full' to wipe it"
  fi
}

cmd_upstream() {
  local kind=${1:?usage: playground.sh upstream clean|conflict}
  local c; c=$(pg_clone "$PG_ROOT")
  case "$kind" in
    clean)
      printf '\n# Sandbox: harmless upstream change (%s)\n' "$(date -u +%FT%TZ)" \
        >> "$c/.pre-commit-config.yaml"
      env "${UNSIGNED[@]}" git -C "$c" commit -qam "Add a harmless pre-commit note (sandbox clean change)"
      ;;
    conflict)
      # a new dependency inside the commented ignore block that
      # downstreams customize (the 2024-10-30 shape). Byte-stable on
      # purpose — rerun it after a reset and rerere recognizes it.
      if grep -q 'actions/upload-artifact' "$c/.github/dependabot.yml"; then
        die "conflict change already applied — reset first"
      fi
      awk '{print} /dependency-name: actions\/setup-python/ && !done {
             print "    #   - dependency-name: actions/upload-artifact"; done=1
           }' "$c/.github/dependabot.yml" > "$TMP/dependabot.yml"
      cat "$TMP/dependabot.yml" > "$c/.github/dependabot.yml"
      env "${UNSIGNED[@]}" git -C "$c" commit -qam "Add actions/upload-artifact to the Dependabot ignore list"
      ;;
    *) die "unknown upstream kind: $kind (clean|conflict)";;
  esac
  git -C "$c" push -q origin develop
  say "pushed upstream '$kind' change to $PG_ORG/$PG_ROOT @ $(git -C "$c" rev-parse --short develop)"
  say "next: scripts/playground.sh sync skel   (then cascade: sync role)"
}

cmd_interloper() {
  local repo parent; read -r repo parent < <(parent_of_tier "${1:?usage: playground.sh interloper skel|role}")
  assert_sandbox "$repo"
  local c; c=$(pg_clone "$repo")
  printf '# Interloper\n\nA feature PR that reached develop mid-review (%s).\n' \
    "$(date -u +%FT%TZ)" > "$c/SANDBOX-INTERLOPER.md"
  git -C "$c" add SANDBOX-INTERLOPER.md
  env "${UNSIGNED[@]}" git -C "$c" commit -qm "Add interloper file (simulates a feature PR merged mid-review)"
  git -C "$c" push -q origin develop
  say "interloper commit on $PG_ORG/$repo develop — merging its sync PR now demos the LEASE REFUSAL"
}

cmd_meddle() {
  local repo parent; read -r repo parent < <(parent_of_tier "${1:?usage: playground.sh meddle skel|role}")
  assert_sandbox "$repo"
  local c; c=$(pg_clone "$repo")
  git -C "$c" rev-parse -q --verify origin/lineage/sync >/dev/null \
    || die "no origin/lineage/sync on $repo — run a sync --push first"
  git -C "$c" switch -qc hand origin/lineage/sync
  printf 'A well-meaning human edited the bot branch (%s).\n' "$(date -u +%FT%TZ)" \
    > "$c/SANDBOX-HAND-EDIT.txt"
  git -C "$c" add SANDBOX-HAND-EDIT.txt
  env "${UNSIGNED[@]}" git -C "$c" commit -qm "Hand edit on the sync branch (simulated human)"
  git -C "$c" push -q origin HEAD:refs/heads/lineage/sync
  say "human commit on $repo origin/lineage/sync — the next sync --push demos the NO-CLOBBER refusal"
}

cmd_sync() {
  local repo parent; read -r repo parent < <(parent_of_tier "${1:?usage: playground.sh sync skel|role [sync.sh args]}")
  shift
  assert_sandbox "$repo"
  [[ -d "$PG_CACHE/.git" ]] || die "playground cache missing — run setup first"
  ORG_URL="$PG_URL" WORK_DIR="$PG_WORK" LOG_DIR="$PG_WORK/logs" CACHE_DIR="$PG_CACHE" \
    "$ROOT/scripts/sync.sh" --parent "$parent" "$repo" "$@"
}

# publish/update the gh EXTENSION in the sandbox: real cisagov
# gh-skeleton history with our lineage subcommands + vendored harness
# committed on top — the same commits a future upstream PR would carry.
# Team install: gh extension install $PG_ORG/gh-skeleton
cmd_ext() {
  local name=gh-skeleton ext="$TMP/ext"
  assert_sandbox "$name"
  if ! repo_exists "$name"; then
    say "creating $PG_ORG/$name (seed: $SEED_ORG/$name, full history)"
    gh repo create "$PG_ORG/$name" --public \
      --description "SANDBOX — gh skeleton extension + lineage sync subcommands (incubating; upstream: $SEED_ORG/$name)" >/dev/null
    repo_exists "$name" || die "$PG_ORG/$name did not resolve canonically after creation"
    git clone -q "https://github.com/$SEED_ORG/$name.git" "$ext"
    git -C "$ext" remote add sandbox "$PG_URL/$name.git"
    git -C "$ext" push -q sandbox develop:develop
    gh api -X PATCH "repos/$PG_ORG/$name" -f default_branch=develop >/dev/null
  else
    git clone -q "$PG_URL/$name.git" "$ext"
    git -C "$ext" remote add sandbox "$PG_URL/$name.git"
  fi
  cp "$ROOT/extension/gh-skeleton" "$ext/gh-skeleton"
  mkdir -p "$ext/scripts"
  cp "$ROOT/scripts/common.sh" "$ROOT/scripts/setup-shared-cache.sh" \
     "$ROOT/scripts/linearize.sh" "$ROOT/scripts/verify-linearization.sh" \
     "$ROOT/scripts/sync.sh" "$ROOT/scripts/verify-sync.sh" \
     "$ROOT/scripts/publish.sh" "$ROOT/scripts/cache-push.sh" \
     "$ROOT/scripts/show-stop.sh" "$ROOT/scripts/resolve-stop.sh" \
     "$ROOT/scripts/continue-stop.sh" "$ROOT/scripts/smoke-test-sync.sh" \
     "$ext/scripts/"
  git -C "$ext" add gh-skeleton scripts
  if git -C "$ext" -c commit.gpgsign=false diff --cached --quiet; then
    say "extension is already up to date"
  else
    env "${UNSIGNED[@]}" git -C "$ext" commit -q \
      -m "Add lineage sync and linearization subcommands" \
      -m "Vendors the rerere linearization harness under scripts/ and
dispatches sync/linearize/verify/verify-sync/publish/cache/stop/smoke
to it, ahead of the existing option parser. State lives under
GH_SKELETON_HOME (default ~/.local/share/gh-skeleton)."
    git -C "$ext" push -q sandbox develop:develop
    say "extension published: $PG_URL/$name (gh extension install $PG_ORG/$name)"
  fi
}

cmd_kit() { # publish/update $PG_ORG/$KIT_REPO so the TEAM can play
  local kit="$TMP/kit"
  if ! repo_exists "$KIT_REPO"; then
    say "creating $PG_ORG/$KIT_REPO"
    gh repo create "$PG_ORG/$KIT_REPO" --public \
      --description "SANDBOX — lineage sync playground kit: scripts + docs to kick the tires (start at the README)" >/dev/null
  fi
  git clone -q "$PG_URL/$KIT_REPO.git" "$kit" 2>/dev/null
  git -C "$kit" checkout -qB develop

  mkdir -p "$kit/scripts" "$kit/ci" "$kit/docs"
  cp "$ROOT/scripts/common.sh" "$ROOT/scripts/setup-shared-cache.sh" \
     "$ROOT/scripts/sync.sh" "$ROOT/scripts/verify-sync.sh" \
     "$ROOT/scripts/linearize.sh" "$ROOT/scripts/verify-linearization.sh" \
     "$ROOT/scripts/smoke-test-sync.sh" "$ROOT/scripts/playground.sh" \
     "$kit/scripts/"
  cp "$ROOT/ci/lineage-publish.yml" "$ROOT/ci/no-upstream-merges.yml" "$kit/ci/"
  rm -rf "$kit/ci/rulesets" && cp -R "$ROOT/ci/rulesets" "$kit/ci/rulesets"
  cp "$ROOT/lineage-rework/playground.md" "$ROOT/lineage-rework/design.md" \
     "$ROOT/lineage-rework/team-decisions.md" "$ROOT/lineage-rework/research.md" \
     "$kit/docs/"

  cat > "$TMP/kit-readme" <<'EOF'
# Lineage sync playground kit (SANDBOX)

Hands-on rehearsal of the rebase-based lineage sync + merge-to-publish
flow, against a live two-tier sandbox lineage in the `@ORG@` org
(sandbox-skeleton-generic → sandbox-skeleton-ansible-role →
sandbox-ansible-role-banner, seeded from the real cisagov histories).
Nothing here can touch cisagov: the driver refuses it outright and
verifies every repo name resolves inside the sandbox (the org's bare
historical names carry rename redirects into cisagov — never create
or push to one).

**Start here: [`docs/playground.md`](docs/playground.md)** — the
day-in-the-life scenarios (~5–10 min each). Design and context:
[`docs/design.md`](docs/design.md),
[`docs/team-decisions.md`](docs/team-decisions.md).

## Prerequisites

- `git` (≥ 2.43) and `gh` logged in (`gh auth status`) with write
  access to the `@ORG@` org repos, and the `workflow` scope
  (`gh auth refresh -s workflow` if pushes of workflow files are
  refused).
- Commit signing that works WITHOUT prompting — the sync re-signs
  every replayed commit. No signing set up? A passwordless SSH
  signing key is fine for the sandbox:

  ```bash
  ssh-keygen -t ed25519 -N '' -f ~/.ssh/sandbox-sign
  git config --global gpg.format ssh
  git config --global user.signingkey ~/.ssh/sandbox-sign
  git config --global commit.gpgsign true
  ```

## Quickstart

```bash
git clone https://github.com/@ORG@/lineage-playground.git
cd lineage-playground
scripts/smoke-test-sync.sh        # validate your environment (local, sandboxed)
scripts/playground.sh status      # see the live sandbox state
scripts/playground.sh reset       # start a session from the baseline
```

Then follow the scenarios in `docs/playground.md`.

## The gh extension (maximum fidelity)

The real tool-to-be lives at `@ORG@/gh-skeleton`: the actual
cisagov/gh-skeleton history with the lineage subcommands committed on
top (`sync`, `linearize`, `verify`, `verify-sync`, `publish`,
`cache`, `stop`, `smoke`). To drive scenarios through it instead of
the scripts:

```bash
# gh allows ONE extension per name — swap out the cisagov one first:
gh extension remove skeleton 2>/dev/null
gh extension install @ORG@/gh-skeleton
gh skeleton smoke                 # sandboxed self-test
# scenario syncs, extension style (same env the playground driver uses):
ORG_URL=https://github.com/@ORG@ \
  CACHE_DIR="$PWD/work/playground/cache" WORK_DIR="$PWD/work/playground" \
  gh skeleton sync --parent sandbox-skeleton-ansible-role sandbox-ansible-role-banner …
# when done, restore the real one:
gh extension remove skeleton && gh extension install cisagov/gh-skeleton
```

## House rules

- **One driver at a time** — the sandbox repos are shared state.
  `playground.sh reset` before a session; shout in the team channel.
- The local source of truth for these scripts/docs is the rerere
  harness tree; update the kit with `playground.sh kit` from there,
  don't edit this repo directly.
EOF
  sed "s/@ORG@/$PG_ORG/g" "$TMP/kit-readme" > "$kit/README.md"

  git -C "$kit" add -A
  if git -C "$kit" diff --cached --quiet; then
    say "kit is already up to date"
  else
    # unsigned on purpose: the signed-commits policy (worklog §31)
    # covers rewritten lineage history and the rr-cache — not a
    # sandbox distribution repo — and kit updates must not depend on
    # a primed gpg agent
    git -C "$kit" -c commit.gpgsign=false commit -qm "Update playground kit from the rerere harness ($(date -I))"
    git -C "$kit" push -q -u origin develop
    gh api -X PATCH "repos/$PG_ORG/$KIT_REPO" -f default_branch=develop >/dev/null
    say "kit published: $PG_URL/$KIT_REPO"
  fi
}

cmd_status() {
  local repo
  for repo in "$PG_ROOT" "$PG_SKEL" "$PG_ROLE"; do
    echo "── $PG_ORG/$repo"
    gh api "repos/$PG_ORG/$repo/branches?per_page=100" \
      --jq '.[] | "  \(.name)  \(.commit.sha[0:12])"' 2>/dev/null || echo "  (missing)"
  done
  for repo in "$PG_SKEL" "$PG_ROLE"; do
    echo "── PRs ($PG_ORG/$repo)"
    gh pr list -R "$PG_ORG/$repo" --state all -L 4 2>/dev/null || true
  done
  echo "── workflow runs ($PG_ORG/$PG_SKEL · $PG_ORG/$PG_ROLE)"
  gh run list -R "$PG_ORG/$PG_SKEL" -L 3 2>/dev/null || true
  gh run list -R "$PG_ORG/$PG_ROLE" -L 3 2>/dev/null || true
}

cmd_nuke() {
  local repo
  for repo in "$PG_ROOT" "$PG_SKEL" "$PG_ROLE"; do
    gh repo delete "$PG_ORG/$repo" --yes 2>/dev/null \
      && say "deleted $PG_ORG/$repo" \
      || warn "could not delete $PG_ORG/$repo (token needs the delete_repo scope: gh auth refresh -s delete_repo)"
  done
  rm -rf "$PG_WORK"
}

VERB=${1:-}; shift || true
case "$VERB" in
  setup)      cmd_setup "$@";;
  reset)      cmd_reset "$@";;
  upstream)   cmd_upstream "$@";;
  interloper) cmd_interloper "$@";;
  meddle)     cmd_meddle "$@";;
  sync)       cmd_sync "$@";;
  ext)        cmd_ext "$@";;
  kit)        cmd_kit "$@";;
  status)     cmd_status "$@";;
  nuke)       cmd_nuke "$@";;
  ''|-h|--help) sed -n '2,/^$/p' "$0";;
  *)          die "unknown verb: $VERB";;
esac
