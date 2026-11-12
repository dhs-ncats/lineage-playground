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
#   4. Merge oracle: a scratch three-way merge of upstream into the
#      old base (over the RECORDED replay base when available),
#      resolved from the same rr-cache, produces the SAME tree as the
#      rebase. Divergence = replay drift or an inconsistent
#      resolution (the sync-era analogue of the §4a empty-diff
#      invariant; cf. worklog §28). Skipped with a note when the
#      scratch merge hits shapes the cache can't resolve.
#   5. Commit accounting over the recorded replay base: every own
#      commit survives, is absorbed upstream (same patch-id), or —
#      when the oracle proved tree equality — is blessed as a
#      legitimate drop.
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

# exact range walks on skewed linear history need a commit-graph AND
# --topo-order (worklog §47); all ranges below use --topo-order
git commit-graph write --reachable 2>/dev/null || true

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
merges=$(git rev-list --topo-order --merges "$UPSTREAM_REF"..develop-sync 2>/dev/null | wc -l)
if [[ "$merges" -eq 0 ]]; then
  ok "no merge commits above upstream ($(git rev-list --topo-order --count "$UPSTREAM_REF"..develop-sync) linear commits)"
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

# 4 — merge oracle: scratch merge tree must equal the rebase tree.
# When the replay base is recorded (S_FROM), merge a SYNTHETIC commit
# carrying the upstream tree with S_FROM as its parent: the computed
# merge base is then exactly the old parent tip instead of some
# deep common ancestor, so the oracle works across parent republishes
# (worklog §47). rerere still applies in the scratch worktree.
oracle_dir=$(mktemp -d)
owt="$oracle_dir/oracle"
oracle=skip
merge_target="$UPSTREAM_REF"
if [[ -n "${S_FROM:-}" ]] && git merge-base --is-ancestor "$S_FROM" "$BASE" 2>/dev/null; then
  merge_target=$(git commit-tree "$UPSTREAM_REF^{tree}" -p "$S_FROM" -m "oracle: upstream tree over recorded base")
fi
git worktree add -q --detach "$owt" "$BASE"
git -C "$owt" merge --no-ff --no-commit "$merge_target" >/dev/null 2>&1 || true
o_remaining=$(git -C "$owt" rerere remaining 2>/dev/null || true)
if [[ -z "$o_remaining" && -z "$(git -C "$owt" ls-files -u)" ]]; then
  o_tree=$(git -C "$owt" write-tree)
  if [[ "$o_tree" == "$(git rev-parse 'develop-sync^{tree}')" ]]; then
    oracle=equal
    ok "merge oracle: scratch merge tree == rebase tree"
  else
    oracle=differ
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

# 5 — commit accounting: nothing silently lost in the replay.
# Identity = author email + author date + subject (what rebase
# preserves even through conflict resolution; patch-ids change
# whenever a resolution or new context touches the diff). The
# accounting base is the recorded replay base (S_FROM: the parent tip
# of the PREVIOUS sync, via the lineage/base tag) so only this repo's
# own delta is accounted; drops are fine when the patch is already
# upstream, and an oracle-equal tree blesses any remainder.
old_base=${S_FROM:-$(git merge-base "$BASE" "$UPSTREAM_REF")}
keys() { git log --topo-order --no-merges --format='%ae|%at|%s' "$1" | sort; }
missing=$(comm -23 <(keys "$old_base..$BASE") <(keys "$UPSTREAM_REF..develop-sync"))
if [[ -z "$missing" ]]; then
  ok "all $(git rev-list --topo-order --count --no-merges "$old_base..$BASE") downstream commits replayed"
else
  up_pids=$(git rev-list --topo-order --no-merges "$old_base..$UPSTREAM_REF" \
    | while read -r c; do git show "$c" | git patch-id --stable | cut -d' ' -f1; done)
  lost="" absorbed=0
  while IFS='|' read -r ae at subj; do
    [[ -z "$subj" ]] && continue
    # no awk early-exit: closing the pipe mid-stream SIGPIPEs git log
    # under pipefail and kills the whole script (exit 141)
    sha=$(git log --topo-order --no-merges --format='%H|%ae|%at|%s' "$old_base..$BASE" \
      | awk -F'|' -v ae="$ae" -v at="$at" -v s="$subj" '$2==ae && $3==at && $4==s && !f {print $1; f=1}')
    pid=$(git show "$sha" | git patch-id --stable | cut -d' ' -f1)
    if [[ -n "$pid" ]] && grep -qx "$pid" <<<"$up_pids"; then
      absorbed=$((absorbed+1))
    else
      lost+="$(git log -1 --format='%h %s' "$sha")\n"
    fi
  done <<<"$missing"
  if [[ -z "$lost" ]]; then
    ok "all downstream commits accounted for ($absorbed absorbed upstream)"
  elif [[ "$oracle" == "equal" ]]; then
    ok "unmatched drops blessed by the merge oracle (tree-identical to the scratch merge):"
    printf '%b' "$lost" | sed 's/^/      /'
  else
    bad "downstream commit(s) missing from develop-sync and not absorbed upstream:"
    printf '%b' "$lost" | sed 's/^/      /'
    inf "  and the merge oracle could not vouch (status: $oracle) — review, then judge"
  fi
fi

# 6
unsigned=$(count_unsigned . "$UPSTREAM_REF..develop-sync")
if [[ "$unsigned" -eq 0 ]]; then
  ok "all $(git rev-list --topo-order --count "$UPSTREAM_REF..develop-sync") commits above upstream are signed"
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
