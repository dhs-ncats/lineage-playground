#!/usr/bin/env bash
# playground.sh — sandbox driver for rehearsing the merge-to-publish
# sync flow on real GitHub (lineage-rework/playground.md is the
# day-in-the-life script). Targets the SANDBOX org only and refuses
# cisagov outright; this is the one script allowed to push without a
# prompt, because it can only ever touch $PG_ORG.
#
# Usage: scripts/playground.sh <verb> [args]
#
# Verbs:
#   setup              create + seed the sandbox repos from the real
#                      (public) cisagov histories; baseline tags;
#                      isolated playground rr-cache
#   reset              force both repos back to baseline, delete
#                      lineage/* branches, close open PRs, wipe the
#                      playground work trees (the playground CACHE
#                      survives — that's scenario 3; `reset --full`
#                      wipes it too)
#   upstream clean     parent change that cannot conflict
#   upstream conflict  parent edit inside the dependabot.yml ignore
#                      block the child customized — the real
#                      2024-10-30 conflict shape, byte-stable so
#                      rerere reuse is demonstrable after reset
#   interloper         push a commit straight to the child's develop
#                      (a "feature PR merged mid-review") — sets up
#                      the lease-refusal demo
#   meddle             push a human commit onto origin/lineage/sync —
#                      sets up the no-clobber demo
#   sync [args…]       run sync.sh against the sandbox child with the
#                      playground env (ORG_URL/WORK_DIR/CACHE_DIR);
#                      e.g. `playground.sh sync`, `playground.sh sync
#                      --push --yes`, `playground.sh sync --resume
#                      "note: …"`
#   kit                publish/update the TEAM kit repo
#                      ($PG_ORG/lineage-playground): these scripts +
#                      ci/ + the lineage-rework docs + a quickstart
#                      README, so teammates clone one repo and play.
#                      Maintainer-run; this tree stays the source of
#                      truth.
#   status             branches, open PRs, latest workflow runs
#   nuke               delete the sandbox repos (needs the
#                      delete_repo token scope)
#
# Env overrides: PG_ORG (default dhs-ncats), SEED_ORG (default
# cisagov — read-only source of truth), PG_PARENT, PG_CHILD,
# KIT_REPO (default lineage-playground).

source "$(dirname "$0")/common.sh"

PG_ORG=${PG_ORG:-dhs-ncats}
SEED_ORG=${SEED_ORG:-cisagov}
PG_PARENT=${PG_PARENT:-skeleton-generic}
PG_CHILD=${PG_CHILD:-skeleton-action-composite}
KIT_REPO=${KIT_REPO:-lineage-playground}
PG_WORK="$ROOT/work/playground"
PG_CACHE="$PG_WORK/cache"
PG_URL="https://github.com/$PG_ORG"

# The whole point of this script is that it CANNOT touch the real org.
[[ "$PG_ORG" == *cisagov* ]] && die "PG_ORG=$PG_ORG — playground.sh refuses to operate on cisagov"
command -v gh >/dev/null || die "playground.sh needs gh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

repo_exists() { gh repo view "$PG_ORG/$1" >/dev/null 2>&1; }

# fresh throwaway clone of a SANDBOX repo; echoes its path
pg_clone() {
  local dir="$TMP/$1.$RANDOM"
  git clone -q "$PG_URL/$1.git" "$dir"
  echo "$dir"
}

seed_repo() { # seed_repo NAME CUSTOMIZE_FN — create + seed from $SEED_ORG
  local name=$1 customize=${2:-}
  if repo_exists "$name"; then
    say "$PG_ORG/$name already exists — leaving it alone (reset to re-baseline)"
    return
  fi
  say "creating $PG_ORG/$name"
  gh repo create "$PG_ORG/$name" --public \
    --description "SANDBOX — lineage merge-to-publish rehearsal ($SEED_ORG/$name stand-in); safe to delete" >/dev/null
  local src="$TMP/seed-$name"
  git clone -q "https://github.com/$SEED_ORG/$name.git" "$src"
  [[ -n "$customize" ]] && "$customize" "$src"
  git -C "$src" tag -f sandbox-baseline develop
  git -C "$src" remote add sandbox "$PG_URL/$name.git"
  git -C "$src" push -q sandbox develop:develop sandbox-baseline
  gh api -X PATCH "repos/$PG_ORG/$name" -f default_branch=develop >/dev/null
  say "seeded $PG_ORG/$name from $SEED_ORG/$name @ $(git -C "$src" rev-parse --short develop)"
}

customize_child() { # point lineage.yml at the sandbox, add the workflows
  local src=$1
  sed "s|github.com[:/]$SEED_ORG/|github.com/$PG_ORG/|" \
    "$src/.github/lineage.yml" > "$TMP/lineage.yml" && cat "$TMP/lineage.yml" > "$src/.github/lineage.yml"
  cp "$ROOT/ci/lineage-publish.yml" "$ROOT/ci/no-upstream-merges.yml" "$src/.github/workflows/"
  git -C "$src" add .github
  git -C "$src" commit -q -m "Add lineage sync workflows (sandbox seed)"
}

cmd_setup() {
  seed_repo "$PG_PARENT"
  seed_repo "$PG_CHILD" customize_child
  if [[ ! -d "$PG_CACHE/.git" ]]; then
    say "initialising ISOLATED playground rr-cache (demo resolutions stay out of the real shared cache)"
    mkdir -p "$PG_CACHE"
    # point the cache remote into the sandbox org too — never the
    # real cisagov/rerere-cache
    CACHE_DIR="$PG_CACHE" CACHE_REMOTE="$PG_URL/rerere-cache.git" \
      "$ROOT/scripts/setup-shared-cache.sh" >/dev/null 2>&1
    [[ -d "$PG_CACHE/.git" ]] || die "playground cache init failed"
  fi
  say "setup done — scenarios: lineage-rework/playground.md"
}

cmd_reset() {
  local full=${1:-}
  local repo c
  for repo in "$PG_PARENT" "$PG_CHILD"; do
    repo_exists "$repo" || die "$PG_ORG/$repo missing — run setup first"
    c=$(pg_clone "$repo")
    git -C "$c" push -q -f origin sandbox-baseline:refs/heads/develop
    while read -r _ ref; do
      [[ -n "$ref" ]] && git -C "$c" push -q origin ":$ref"
    done < <(git -C "$c" ls-remote --heads origin 'lineage/*')
    say "$repo: develop → baseline, lineage/* branches cleared"
  done
  while read -r n; do
    [[ -n "$n" ]] && gh pr close "$n" -R "$PG_ORG/$PG_CHILD" -c "playground reset" >/dev/null \
      && say "closed PR #$n"
  done < <(gh pr list -R "$PG_ORG/$PG_CHILD" --state open --json number --jq '.[].number')
  find "$PG_WORK" -mindepth 1 -maxdepth 1 ! -name cache -exec rm -rf {} +
  if [[ "$full" == "--full" ]]; then
    rm -rf "$PG_CACHE"
    say "playground rr-cache wiped (--full)"
  else
    say "playground rr-cache KEPT (temporal-reuse demo); use 'reset --full' to wipe it"
  fi
}

cmd_upstream() {
  local kind=${1:?usage: playground.sh upstream clean|conflict}
  local c; c=$(pg_clone "$PG_PARENT")
  case "$kind" in
    clean)
      printf '\n# Sandbox: harmless upstream change (%s)\n' "$(date -u +%FT%TZ)" \
        >> "$c/.pre-commit-config.yaml"
      git -C "$c" commit -qam "Add a harmless pre-commit note (sandbox clean change)"
      ;;
    conflict)
      # the 2024-10-30 shape: a new dependency inside the commented
      # ignore block that the child's delta UNCOMMENTS. Byte-stable on
      # purpose — rerun it after a reset and rerere recognizes it.
      if grep -q 'actions/upload-artifact' "$c/.github/dependabot.yml"; then
        die "conflict change already applied — reset first"
      fi
      awk '{print} /dependency-name: actions\/setup-python/ && !done {
             print "    #   - dependency-name: actions/upload-artifact"; done=1
           }' "$c/.github/dependabot.yml" > "$TMP/dependabot.yml"
      cat "$TMP/dependabot.yml" > "$c/.github/dependabot.yml"
      git -C "$c" commit -qam "Add actions/upload-artifact to the Dependabot ignore list"
      ;;
    *) die "unknown upstream kind: $kind (clean|conflict)";;
  esac
  git -C "$c" push -q origin develop
  say "pushed upstream '$kind' change to $PG_ORG/$PG_PARENT @ $(git -C "$c" rev-parse --short develop)"
  say "next: scripts/playground.sh sync"
}

cmd_interloper() {
  local c; c=$(pg_clone "$PG_CHILD")
  printf '# Interloper\n\nA feature PR that reached develop mid-review (%s).\n' \
    "$(date -u +%FT%TZ)" > "$c/SANDBOX-INTERLOPER.md"
  git -C "$c" add SANDBOX-INTERLOPER.md
  git -C "$c" commit -qm "Add interloper file (simulates a feature PR merged mid-review)"
  git -C "$c" push -q origin develop
  say "interloper commit on $PG_ORG/$PG_CHILD develop — merging the sync PR now demos the LEASE REFUSAL"
}

cmd_meddle() {
  local c; c=$(pg_clone "$PG_CHILD")
  git -C "$c" rev-parse -q --verify origin/lineage/sync >/dev/null \
    || die "no origin/lineage/sync to meddle with — run a sync --push first"
  git -C "$c" switch -qc hand origin/lineage/sync
  printf 'A well-meaning human edited the bot branch (%s).\n' "$(date -u +%FT%TZ)" \
    > "$c/SANDBOX-HAND-EDIT.txt"
  git -C "$c" add SANDBOX-HAND-EDIT.txt
  git -C "$c" commit -qm "Hand edit on the sync branch (simulated human)"
  git -C "$c" push -q origin HEAD:refs/heads/lineage/sync
  say "human commit on origin/lineage/sync — the next sync --push demos the NO-CLOBBER refusal"
}

cmd_sync() {
  [[ -d "$PG_CACHE/.git" ]] || die "playground cache missing — run setup first"
  # --parent is explicit: a kit clone has no inventory JSON, and the
  # lineage.yml fallback in common.sh only parses cisagov URLs
  ORG_URL="$PG_URL" WORK_DIR="$PG_WORK" LOG_DIR="$PG_WORK/logs" CACHE_DIR="$PG_CACHE" \
    "$ROOT/scripts/sync.sh" --parent "$PG_PARENT" "$PG_CHILD" "$@"
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
flow, against live sandbox repos in the `@ORG@` org. Nothing here can
touch cisagov: the driver refuses it outright.

**Start here: [`docs/playground.md`](docs/playground.md)** — five
day-in-the-life scenarios (~5–10 min each). Design and context:
[`docs/design.md`](docs/design.md),
[`docs/team-decisions.md`](docs/team-decisions.md).

## Prerequisites

- `git` (≥ 2.43) and `gh` logged in (`gh auth status`) with write
  access to the `@ORG@` org repos, and the `workflow` scope
  (`gh auth refresh -s workflow` if pushes of workflow files are
  refused).
- Commit signing that works WITHOUT prompting — the sync re-signs
  every replayed commit. Test: your key signs headlessly if
  `echo t | gpg --batch --pinentry-mode error -u <KEY> --detach-sign
  >/dev/null` succeeds. No signing set up? A passwordless SSH signing
  key is fine for the sandbox:

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
  for repo in "$PG_PARENT" "$PG_CHILD"; do
    echo "── $PG_ORG/$repo"
    gh api "repos/$PG_ORG/$repo/branches?per_page=100" \
      --jq '.[] | "  \(.name)  \(.commit.sha[0:12])"' 2>/dev/null || echo "  (missing)"
  done
  echo "── PRs ($PG_ORG/$PG_CHILD)"
  gh pr list -R "$PG_ORG/$PG_CHILD" --state all -L 5 2>/dev/null || true
  echo "── workflow runs"
  gh run list -R "$PG_ORG/$PG_CHILD" -L 5 2>/dev/null || true
}

cmd_nuke() {
  local repo
  for repo in "$PG_PARENT" "$PG_CHILD"; do
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
  kit)        cmd_kit "$@";;
  status)     cmd_status "$@";;
  nuke)       cmd_nuke "$@";;
  ''|-h|--help) sed -n '2,/^$/p' "$0";;
  *)          die "unknown verb: $VERB";;
esac
