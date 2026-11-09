#!/usr/bin/env bash
# verify-sync.sh — acceptance checks for a steady-state sync.
# Run after sync.sh completes (sync.sh runs it itself; sync.sh --push
# refuses unless it passes). Local; reads work/<repo>-sync/. Never
# pushes.
#
# Usage: scripts/verify-sync.sh <repo>
#
# Checks:
#   1. develop-sync exists and is a descendant of upstream/<branch>
#   2. No merge commits in upstream..develop-sync
#   3. No leftover conflict markers in tracked files
#   4. Every downstream commit's patch-id survives the rebase, or is
#      accounted for as absorbed upstream (same patch-id already on
#      the parent)
#   5. Merge oracle: a scratch three-way merge of upstream into the
#      old base, resolved from the same rr-cache, produces the SAME
#      tree as the rebase. Divergence = replay drift or an
#      inconsistent resolution (the sync-era analogue of the §4a
#      empty-diff invariant; cf. worklog §28). Skipped with a note
#      when the scratch merge hits shapes the cache can't resolve.
#   6. Every commit above upstream is signed (team policy, worklog §31)
#   7. origin/<branch> still equals the recorded base (fresh fetch —
#      anything merged mid-sync means resync, since the publish lease
#      would fail against it anyway)
#
# Exit 0 = all checks pass; 1 = at least one hard failure.

source "$(dirname "$0")/common.sh"

REPO=${1:?usage: verify-sync.sh <repo>}
WT="$WORK_DIR/$REPO-sync"
[[ -d "$WT/.git" ]] || die "no work tree at $WT — run sync.sh first"
cd "$WT"

[[ -f .git/SYNC_STATE ]] || die "no sync state — run sync.sh first"
# shellcheck disable=SC1091
source .git/SYNC_STATE
BRANCH=${S_BRANCH:-develop}
BASE=${S_BASE:?SYNC_STATE lacks S_BASE}

UPSTREAM_REF="upstream/$BRANCH"
git rev-parse -q --verify "$UPSTREAM_REF" >/dev/null \
  || UPSTREAM_REF="upstream/$(git remote show upstream | sed -n 's/.*HEAD branch: //p')"

pass=0 fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
inf() { printf '  \033[33m·\033[0m %s\n' "$*"; }

echo "verify-sync: $REPO  (upstream=$UPSTREAM_REF base=${BASE:0:12})"

# 1
if git rev-parse -q --verify develop-sync >/dev/null; then
  if git merge-base --is-ancestor "$UPSTREAM_REF" develop-sync; then
    ok "develop-sync descends from $UPSTREAM_REF"
  else
    bad "develop-sync is NOT a descendant of $UPSTREAM_REF"
  fi
else
  bad "develop-sync branch missing"
fi

# 2
merges=$(git rev-list --merges "$UPSTREAM_REF"..develop-sync 2>/dev/null | wc -l)
if [[ "$merges" -eq 0 ]]; then
  ok "no merge commits above upstream ($(git rev-list --count "$UPSTREAM_REF"..develop-sync) linear commits)"
else
  bad "$merges merge commit(s) above upstream"
fi

# 3
git checkout -qf develop-sync
if git grep -nI -e '^<<<<<<< ' -e '^>>>>>>> ' -- . >/dev/null 2>&1; then
  bad "conflict markers present in tracked files:"
  git grep -lI -e '^<<<<<<< ' -- . | sed 's/^/      /'
else
  ok "no conflict markers in tracked files"
fi

# 4 — commit accounting: nothing silently lost in the replay.
# Identity = author email + author date + subject (what rebase
# preserves even through conflict resolution; patch-ids change
# whenever a resolution or new context touches the diff). A commit
# missing from develop-sync is fine only if its ORIGINAL patch is
# already upstream (rebase drops it as already-applied).
old_base=$(git merge-base "$BASE" "$UPSTREAM_REF")
keys() { git log --no-merges --format='%ae|%at|%s' "$1" | sort; }
missing=$(comm -23 <(keys "$old_base..$BASE") <(keys "$UPSTREAM_REF..develop-sync"))
if [[ -z "$missing" ]]; then
  ok "all $(git rev-list --count --no-merges "$old_base..$BASE") downstream commits replayed"
else
  up_pids=$(git rev-list --no-merges "$old_base..$UPSTREAM_REF" \
    | while read -r c; do git show "$c" | git patch-id --stable | cut -d' ' -f1; done)
  lost="" absorbed=0
  while IFS='|' read -r ae at subj; do
    [[ -z "$subj" ]] && continue
    sha=$(git log --no-merges --format='%H|%ae|%at|%s' "$old_base..$BASE" \
      | awk -F'|' -v ae="$ae" -v at="$at" -v s="$subj" '$2==ae && $3==at && $4==s {print $1; exit}')
    pid=$(git show "$sha" | git patch-id --stable | cut -d' ' -f1)
    if [[ -n "$pid" ]] && grep -qx "$pid" <<<"$up_pids"; then
      absorbed=$((absorbed+1))
    else
      lost+="$(git log -1 --format='%h %s' "$sha")\n"
    fi
  done <<<"$missing"
  if [[ -z "$lost" ]]; then
    ok "all downstream commits accounted for ($absorbed absorbed upstream)"
  else
    bad "downstream commit(s) missing from develop-sync and not absorbed upstream:"
    printf '%b' "$lost" | sed 's/^/      /'
    inf "  if check 5 passes, the change arrived as a different upstream patch — review, then judge"
  fi
fi

# 5 — merge oracle: scratch merge tree must equal the rebase tree
oracle_dir=$(mktemp -d)
owt="$oracle_dir/oracle"
git worktree add -q --detach "$owt" "$BASE"
git -C "$owt" merge --no-ff --no-commit "$UPSTREAM_REF" >/dev/null 2>&1 || true
o_remaining=$(git -C "$owt" rerere remaining 2>/dev/null || true)
if [[ -z "$o_remaining" && -z "$(git -C "$owt" ls-files -u)" ]]; then
  o_tree=$(git -C "$owt" write-tree)
  if [[ "$o_tree" == "$(git rev-parse 'develop-sync^{tree}')" ]]; then
    ok "merge oracle: scratch merge tree == rebase tree"
  else
    bad "merge oracle: scratch merge tree differs from the rebase result"
    git -C "$owt" diff --shortstat "$o_tree" 'develop-sync^{tree}' 2>/dev/null | sed 's/^ */      /' || true
    inf "  replay drift or inconsistent resolution — fix the sync, don't explain the diff away"
  fi
else
  n_unres=$(echo "$o_remaining" | grep -c . || true)
  ok "merge oracle skipped: $n_unres path(s) the cache can't auto-resolve in a scratch merge"
  inf "  content not independently confirmed — review $LOG_DIR/$REPO-sync-resolutions.md with care"
fi
git -C "$owt" merge --abort >/dev/null 2>&1 || true
git worktree remove --force "$owt" >/dev/null 2>&1 || true
rm -rf "$oracle_dir"

# 6
unsigned=$(count_unsigned . "$UPSTREAM_REF..develop-sync")
if [[ "$unsigned" -eq 0 ]]; then
  ok "all $(git rev-list --count "$UPSTREAM_REF..develop-sync") commits above upstream are signed"
else
  bad "$unsigned unsigned commit(s) above upstream — team policy requires signed commits (worklog §31)"
fi

# 7 — freshness: the publish lease will be taken against BASE
git fetch -q origin
if [[ "$(git rev-parse "origin/$BRANCH")" == "$BASE" ]]; then
  ok "origin/$BRANCH unchanged since sync started"
else
  bad "origin/$BRANCH moved since sync started — rerun sync.sh --fresh $REPO (the publish lease would fail anyway)"
fi

echo
echo "result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
