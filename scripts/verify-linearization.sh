#!/usr/bin/env bash
# verify-linearization.sh — acceptance checks for a linearized repo.
# Run after linearize.sh completes. Local; reads work/<repo>/. Never pushes.
#
# Usage: scripts/verify-linearization.sh <repo>
#
# Checks:
#   1. archive/pre-linearization tag exists
#   2. develop-linear exists and is a descendant of upstream/<branch>
#   3. No merge commits in upstream..develop-linear
#   4. Content diff archive/pre-linearization..develop-linear is empty
#      (hard fail — the §4a invariant; linearize.sh refuses final
#      modes when the invariant doesn't hold, so any diff here is a
#      resolution error, not something to explain away)
#   5. No leftover conflict markers in tracked files
#   6. Every commit in upstream/<branch> is an ancestor (nothing dropped)
#   7. origin/<branch> hasn't moved since the archive tag (fresh
#      fetch — the "PR landed mid-campaign" detector; publish gate)
#
# Exit 0 = all checks pass; 1 = at least one hard failure.

source "$(dirname "$0")/common.sh"

REPO=${1:?usage: verify-linearization.sh <repo>}
WT="$WORK_DIR/$REPO"
[[ -d "$WT/.git" ]] || die "no work tree at $WT — run linearize.sh first"
cd "$WT"

# Date-preserved linear history carries multi-year committer-date
# skew, and git's default range/negation walks are date-slop
# HEURISTICS that silently return wrong sets under it (worklog §47).
# Exact walks need BOTH a commit-graph (generation numbers) and
# --topo-order; every range below uses --topo-order, and this
# provides the graph.
git commit-graph write --reachable 2>/dev/null || true

BRANCH=develop
if [[ -f .git/LINEARIZE_STATE ]]; then
  # shellcheck disable=SC1091
  source .git/LINEARIZE_STATE
  BRANCH=${S_BRANCH:-develop}
fi
UPSTREAM_REF="upstream/$BRANCH"
git rev-parse -q --verify "$UPSTREAM_REF" >/dev/null \
  || UPSTREAM_REF="upstream/$(git remote show upstream | sed -n 's/.*HEAD branch: //p')"

pass=0 fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
inf() { printf '  \033[33m·\033[0m %s\n' "$*"; }

echo "verify: $REPO  (upstream=$UPSTREAM_REF)"

# 1
if git rev-parse -q --verify archive/pre-linearization >/dev/null; then
  ok "archive/pre-linearization = $(git rev-parse --short archive/pre-linearization)"
else
  bad "archive/pre-linearization tag missing"
fi

# 2
if git rev-parse -q --verify develop-linear >/dev/null; then
  if git merge-base --is-ancestor "$UPSTREAM_REF" develop-linear; then
    ok "develop-linear descends from $UPSTREAM_REF"
  else
    bad "develop-linear is NOT a descendant of $UPSTREAM_REF"
  fi
else
  bad "develop-linear branch missing"
fi

# 3
merges=$(git rev-list --topo-order --merges "$UPSTREAM_REF"..develop-linear 2>/dev/null | wc -l)
if [[ "$merges" -eq 0 ]]; then
  ok "no merge commits above upstream ($(git rev-list --topo-order "$UPSTREAM_REF"..develop-linear | wc -l) linear commits)"
else
  bad "$merges merge commit(s) remain above upstream"
fi

# 4
diffstat=$(git diff --shortstat archive/pre-linearization develop-linear 2>/dev/null || true)
if [[ -z "$diffstat" ]]; then
  ok "content identical to archive/pre-linearization"
else
  bad "content differs from archive/pre-linearization: $diffstat"
  inf "  any diff is a resolution error to fix, not explain away (§4a)"
  inf "  review with: git -C $WT diff archive/pre-linearization develop-linear"
fi

# 5  (-f: a dirty tree from a failed run shouldn't turn this into a
#     confusing "would be overwritten by checkout" error)
git checkout -qf develop-linear
if git grep -nI -e '^<<<<<<< ' -e '^>>>>>>> ' -- . >/dev/null 2>&1; then
  bad "conflict markers present in tracked files:"
  git grep -lI -e '^<<<<<<< ' -- . | sed 's/^/      /'
else
  ok "no conflict markers in tracked files"
fi

# 6
missing=$(git rev-list --topo-order "$UPSTREAM_REF" ^develop-linear | wc -l)
if [[ "$missing" -eq 0 ]]; then
  ok "all upstream commits are ancestors"
else
  bad "$missing upstream commit(s) not reachable from develop-linear"
fi

# 7 — publish freshness: nothing landed on origin since we archived
git fetch -q origin
if [[ "$(git rev-parse "origin/$BRANCH")" \
      == "$(git rev-parse 'archive/pre-linearization^{commit}')" ]]; then
  ok "origin/$BRANCH unchanged since archive tag"
else
  bad "origin/$BRANCH moved since archive tag — cherry-pick the new commits onto develop-linear and move the tag (cf. tracker note ²)"
fi

echo
echo "result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
