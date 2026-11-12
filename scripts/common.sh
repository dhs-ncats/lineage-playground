#!/usr/bin/env bash
# Shared helpers for the linearization harness.
# shellcheck shell=bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# All overridable via the environment (smoke-test.sh runs the whole
# harness against throwaway dirs this way).
WORK_DIR=${WORK_DIR:-"$ROOT/work"}
CACHE_DIR=${CACHE_DIR:-"$ROOT/rr-cache"}
LOG_DIR=${LOG_DIR:-"$ROOT/campaign/logs"}
INV_JSON=${INV_JSON:-"$ROOT/campaign/downstream-inventory.json"}

# SSH so the same remotes work for the eventual (human-gated) pushes.
# Override for keyless environments: ORG_URL=https://github.com/cisagov
ORG_URL=${ORG_URL:-git@github.com:cisagov}

mkdir -p "$WORK_DIR" "$LOG_DIR"

say()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# parent_of REPO — read parent skeleton from campaign/downstream-inventory.json
# if present, else from a checked-out lineage.yml, else fail.
parent_of() {
  local repo=$1
  if [[ -r "$INV_JSON" ]]; then
    local p
    p=$(jq -r --arg r "$repo" '.parents[$r] // empty' "$INV_JSON")
    [[ -n "$p" ]] && { echo "$p"; return; }
  fi
  local f="$WORK_DIR/$repo/.github/lineage.yml"
  if [[ -r "$f" ]]; then
    sed -n 's|.*remote-url:.*github.com[:/]cisagov/\([A-Za-z0-9._-]*\)\.git.*|\1|p' "$f" | head -1
    return
  fi
  return 1
}

# Locate rerere-train.sh once; export RERERE_TRAIN.
find_rerere_train() {
  local candidates=(
    "${RERERE_TRAIN:-}"
    /usr/share/doc/git/contrib/rerere-train.sh
    /usr/share/git-core/contrib/rerere-train.sh
    "$(brew --prefix git 2>/dev/null)/share/git-core/contrib/rerere-train.sh"
    "$ROOT/scripts/vendor/rerere-train.sh"
  )
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -r "$c" ]] && { export RERERE_TRAIN="$c"; return; }
  done
  warn "rerere-train.sh not found; fetching upstream copy"
  mkdir -p "$ROOT/scripts/vendor"
  curl -fsSL -o "$ROOT/scripts/vendor/rerere-train.sh" \
    https://raw.githubusercontent.com/git/git/master/contrib/rerere-train.sh \
    || die "could not obtain rerere-train.sh"
  export RERERE_TRAIN="$ROOT/scripts/vendor/rerere-train.sh"
}

# ensure_identity DIR — let the operator's own identity (global or
# system config) win. Drops a previously-written harness fallback from
# local config when a real identity resolves without it; writes the
# fallback only when git can resolve nothing at all (rerere-train and
# the cache commits need *some* committer identity).
ensure_identity() {
  local dir=$1 key
  for key in user.name user.email; do
    case "$(git -C "$dir" config --local "$key" 2>/dev/null)" in
      linearize-harness|linearize@localhost)
        git -C "$dir" config --local --unset "$key";;
    esac
  done
  if ! git -C "$dir" config user.name >/dev/null 2>&1 || ! git -C "$dir" config user.email >/dev/null 2>&1; then
    warn "no git identity resolves in $dir — falling back to linearize-harness (commits will be AUTHORED as the harness; configure user.name/user.email for real authorship — worklog §41)"
  fi
  git -C "$dir" config user.name  >/dev/null 2>&1 || git -C "$dir" config user.name  "linearize-harness"
  git -C "$dir" config user.email >/dev/null 2>&1 || git -C "$dir" config user.email "linearize@localhost"
}

# commit_signed DIR REF — true when the commit carries a gpg signature.
commit_signed() {
  git -C "$1" cat-file commit "$2" | grep -q '^gpgsig'
}

# count_unsigned DIR RANGE — number of commits in RANGE lacking one.
count_unsigned() {
  local n=0 c
  while read -r c; do
    commit_signed "$1" "$c" || n=$((n+1))
  done < <(git -C "$1" rev-list --topo-order "$2")
  echo "$n"
}

# Configure a repo's git for the harness. Idempotent.
prep_repo() {
  local dir=$1
  ensure_identity "$dir"
  git -C "$dir" config rerere.enabled true
  git -C "$dir" config rerere.autoUpdate true
  git -C "$dir" config advice.detachedHead false
  git -C "$dir" config advice.skippedCherryPicks false
  # Pin behavior the harness depends on against global overrides
  # (worklog §29): the stop loop only understands the MERGE backend
  # (a global rebase.backend=apply wedged real runs while the sandboxed
  # smoke test passed); conflict TEXT is what rerere fingerprints, so
  # one conflict style teamwide or the shared cache silently misses.
  # Commit SIGNING is deliberately NOT pinned: team policy is signed
  # commits everywhere (worklog §31) — linearize.sh preflights that
  # signing works, and publish.sh refuses unsigned history. The cache
  # repo inherits the same config; cache-push.sh refuses unsigned
  # history just like publish.sh (worklog §39).
  git -C "$dir" config rebase.backend merge
  git -C "$dir" config merge.conflictstyle merge
  # The harness drives git at script speed and trusts index/status to
  # be accurate NOW. Async/cached state sources have produced stale
  # reads (worklog §27 status race; §32 nondeterministic wedges on a
  # box suspected of fsmonitor/watchman) — force full rescans.
  git -C "$dir" config core.fsmonitor false
  git -C "$dir" config core.untrackedCache false
  # No background maintenance in throwaway clones: a mid-replay
  # auto-gc races the sequencer (worklog §33), and `git gc` always
  # runs `git rerere gc`, which would prune the SHARED cache through
  # the symlink under aggressive gc.rerere* settings.
  git -C "$dir" config gc.auto 0
  git -C "$dir" config maintenance.auto false
}

# Symlink REPO/.git/rr-cache -> shared cache. Refuses if a real dir
# with entries already exists (would lose them).
link_cache() {
  local dir=$1
  local target="$dir/.git/rr-cache"
  [[ -d "$CACHE_DIR/.git" ]] || die "shared cache not initialised — run scripts/setup-shared-cache.sh"
  if [[ -L "$target" ]]; then
    :
  elif [[ -d "$target" ]]; then
    if [[ -n "$(ls -A "$target" 2>/dev/null)" ]]; then
      die "$target exists and is non-empty; move it aside first"
    fi
    rmdir "$target"
  fi
  ln -sfn "$CACHE_DIR" "$target"
}
