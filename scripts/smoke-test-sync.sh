#!/usr/bin/env bash
# smoke-test-sync.sh — sandboxed end-to-end test of the steady-state
# sync path (sync.sh / verify-sync.sh) plus a local simulation of the
# merge-to-publish mechanics from ci/lineage-publish.yml. Zero side
# effects on the real work/, rr-cache/, campaign/ (env overrides, as
# smoke-test.sh). sync.sh skips its gh PR/status steps for non-GitHub
# ORG_URLs, so what's exercised here is the pure-git contract the
# workflow relies on: merge-commit parent recovery and the develop
# lease.
#
# Covers:
#   1. clean sync (no conflicts): zero stops, verify 7/7
#   2. --push artifacts: decoy base at the recorded SHA, lineage/sync
#      pushed, pushed-sha marker written
#   3. publish simulation: merge into the decoy → lease-push of the
#      reviewed SHA to develop succeeds; review branches retired
#   4. conflicted sync: pause (exit 2) → manual resolve → --resume →
#      verify 7/7; then temporal reuse — a fresh rerun auto-resolves
#      the same shape from the shared cache (zero manual)
#   5. lease protection: a commit reaching develop mid-review makes
#      the publish push FAIL and leaves develop untouched
#   6. no-clobber: a foreign commit on origin/lineage/sync (not in
#      develop, no recoverable marker) makes --push refuse
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name  "Smoke Test"
git config --file "$GIT_CONFIG_GLOBAL" user.email "smoke@example.com"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch develop
git config --file "$GIT_CONFIG_GLOBAL" safe.directory '*'
ssh-keygen -q -t ed25519 -N '' -f "$T/sigkey"
git config --file "$GIT_CONFIG_GLOBAL" gpg.format ssh
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$T/sigkey"
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign true

export ORG_URL="$T/org" WORK_DIR="$T/work" CACHE_DIR="$T/cache" LOG_DIR="$T/logs"
mkdir -p "$ORG_URL" "$CACHE_DIR"

fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }

echo "env: $(git --version) on $(uname -s)"

WT="$WORK_DIR/child-sync"
BARE="$ORG_URL/child.git"
RESLOG="$LOG_DIR/child-sync-resolutions.md"

# ── synthetic lineage: parent with 3 commits; child is ALREADY
#    LINEAR (post-linearization steady state): parent@P3 + C1 + C2 ──
git init -q "$T/p" && cd "$T/p"
printf 'hook-a\n' > config.yml
git add -A && git commit -qm "P1: base"
printf 'hook-a\nhook-b\n' > config.yml
git commit -qam "P2: add hook-b"
printf 'hook-a\nhook-b\nhook-c\n' > config.yml
git commit -qam "P3: add hook-c"
git clone -q --bare . "$ORG_URL/parent.git"

git init -q "$T/c" && cd "$T/c"
git remote add upstream "$ORG_URL/parent.git" && git fetch -q upstream
git switch -qc develop upstream/develop
printf 'hook-a\nhook-b\nhook-c\nchild-hook\n' > config.yml
echo child > child.txt
git add -A && git commit -qm "C1: customize config, add child.txt"
echo more >> child.txt && git commit -qam "C2: more child work"
git clone -q --bare . "$BARE"

parent_bump() { # parent_bump MSG — commit whatever $T/p holds, push
  git -C "$T/p" add -A && git -C "$T/p" commit -qm "$1"
  git -C "$T/p" push -q "$ORG_URL/parent.git" develop:develop
}

# simulate_publish — what GitHub + ci/lineage-publish.yml do on merge:
# merge lineage/sync into the decoy (clean by construction — the
# decoy tip is an ancestor of head), recover the develop snapshot
# from the decoy's name (the workflow reads the full SHA from the PR
# body marker; same value), verify the reviewed SHA is the merge's
# second parent, lease-push to develop, retire the review branches.
# Returns 1 when the lease refuses.
simulate_publish() {
  local m="$T/merge-sim" decoy snap embedded headsha M
  rm -rf "$m"
  git clone -q "$BARE" "$m"
  decoy=$(git -C "$m" for-each-ref --format='%(refname:short)' \
    'refs/remotes/origin/lineage/sync-base-*' | head -1)
  decoy=${decoy#origin/}
  [[ -n "$decoy" ]] || { echo "    (no decoy branch found)"; return 2; }
  headsha=$(git -C "$m" rev-parse origin/lineage/sync)
  git -C "$m" switch -qc merge-target "origin/$decoy"
  git -C "$m" merge -q --no-ff -m "Merge pull request (simulated)" origin/lineage/sync \
    || { echo "    (merge into decoy conflicted — must be clean by construction)"; return 2; }
  git -C "$m" push -q origin "HEAD:refs/heads/$decoy"
  M=$(git -C "$m" rev-parse HEAD)
  embedded=${decoy#lineage/sync-base-}
  snap=$(git -C "$m" rev-parse -q --verify "${embedded}^{commit}") \
    || { echo "    (snapshot $embedded unresolvable)"; return 2; }
  [[ "$(git -C "$m" rev-parse "$M^2")" == "$headsha" ]] \
    || { echo "    (merge second parent != reviewed head)"; return 2; }
  if git -C "$m" push -q --force-with-lease="refs/heads/develop:$snap" \
       origin "$headsha:refs/heads/develop" 2>/dev/null; then
    git -C "$m" push -q origin ":refs/heads/$decoy" ":refs/heads/lineage/sync"
    return 0
  fi
  return 1
}

echo "── setup-shared-cache"
"$HERE/setup-shared-cache.sh" >/dev/null
[[ -d "$CACHE_DIR/.git" ]] && ok "shared cache initialised" || bad "cache init"

echo "── 1. clean sync (upstream change, no conflicts)"
echo other > "$T/p/other.txt"
parent_bump "P4: add other.txt"
if "$HERE/sync.sh" --parent parent child >/dev/null; then
  ok "sync completed (verify ran inside)"
else
  bad "sync exited $? (expected 0)"
fi
grep -q 'stops=0' "$RESLOG" && ok "zero stops" || bad "expected zero stops"
"$HERE/verify-sync.sh" child >/dev/null && ok "verify-sync 7/7 standalone" || bad "verify-sync failed"

echo "── 2. --push artifacts (local remote: non-interactive, gh skipped)"
"$HERE/sync.sh" --push child >/dev/null || bad "--push exited $?"
S_BASE=$(sed -n 's/^S_BASE=//p' "$WT/.git/SYNC_STATE")
S_ONTO=$(sed -n 's/^S_ONTO=//p' "$WT/.git/SYNC_STATE")
DECOY="lineage/sync-base-${S_BASE:0:12}"
head=$(git -C "$WT" rev-parse develop-sync)
[[ "$(git -C "$BARE" rev-parse "refs/heads/$DECOY" 2>/dev/null)" == "$S_ONTO" ]] \
  && ok "decoy tip = upstream snapshot (name records the develop SHA)" || bad "decoy base wrong/missing"
[[ "$(git -C "$BARE" rev-parse refs/heads/lineage/sync 2>/dev/null)" == "$head" ]] \
  && ok "lineage/sync pushed" || bad "lineage/sync wrong/missing"
[[ "$(cat "$WT/.git/SYNC_PUSHED" 2>/dev/null)" == "$head" ]] \
  && ok "pushed-sha marker written" || bad "marker missing"

echo "── 3. publish simulation (merge → lease-push → retire)"
if simulate_publish; then
  ok "lease-guarded publish succeeded"
else
  bad "publish simulation failed (rc=$?)"
fi
[[ "$(git -C "$BARE" rev-parse refs/heads/develop)" == "$head" ]] \
  && ok "develop == the reviewed head SHA" || bad "develop is not the reviewed SHA"
if git -C "$BARE" rev-parse -q --verify refs/heads/lineage/sync >/dev/null; then
  bad "lineage/sync not retired after publish"
else
  ok "review branches retired"
fi

echo "── 4. conflicted sync: pause → resolve → resume; then temporal reuse"
printf 'hook-a\nhook-b\nhook-c\nhook-d\n' > "$T/p/config.yml"
parent_bump "P5: add hook-d"
rc=0; "$HERE/sync.sh" --fresh --parent parent child >/dev/null || rc=$?
if [[ $rc -eq 2 && -f "$WT/.git/SYNC_STOP" ]]; then
  ok "paused at the new conflict shape (exit 2)"
else
  bad "expected pause with exit 2, got rc=$rc"
fi
printf 'hook-a\nhook-b\nhook-c\nhook-d\nchild-hook\n' > "$WT/config.yml"
git -C "$WT" add config.yml
rc=0; "$HERE/sync.sh" --resume child "smoke: union of hook-d + child-hook" >/dev/null || rc=$?
[[ $rc -eq 0 ]] && ok "resumed and completed" || bad "resume exited $rc"
"$HERE/verify-sync.sh" child >/dev/null && ok "verify-sync 7/7 after manual stop" || bad "verify-sync failed"
rc=0; "$HERE/sync.sh" --fresh --parent parent child >/dev/null || rc=$?
if [[ $rc -eq 0 ]] && grep -q 'manual=0' "$RESLOG"; then
  ok "temporal reuse: rerun auto-resolved from the shared cache (manual=0)"
else
  bad "rerun did not auto-resolve (rc=$rc)"
fi

echo "── 5. lease protection: develop moves mid-review"
"$HERE/sync.sh" --push child >/dev/null || bad "--push exited $?"
m2="$T/interloper"; rm -rf "$m2"
git clone -q "$BARE" "$m2"
echo interloper > "$m2/i.txt"
git -C "$m2" add -A && git -C "$m2" commit -qm "feature: merged mid-review"
git -C "$m2" push -q origin develop:develop
interloper_tip=$(git -C "$m2" rev-parse develop)
if simulate_publish; then
  bad "lease push SUCCEEDED over a moved develop (must refuse)"
else
  ok "lease refused: develop moved mid-review"
fi
[[ "$(git -C "$BARE" rev-parse refs/heads/develop)" == "$interloper_tip" ]] \
  && ok "develop untouched by the failed publish" || bad "develop was altered"

echo "── 6. no-clobber: foreign commits on origin/lineage/sync"
m3="$T/human"; rm -rf "$m3"
git clone -q "$BARE" "$m3"
git -C "$m3" switch -qc hand origin/lineage/sync
echo tweak > "$m3/h.txt"
git -C "$m3" add -A && git -C "$m3" commit -qm "human: hand edit on the sync branch"
git -C "$m3" push -q origin HEAD:refs/heads/lineage/sync
rc=0; "$HERE/sync.sh" --fresh --parent parent child >/dev/null || rc=$?
[[ $rc -eq 0 ]] || bad "resync before no-clobber test exited $rc"
rc=0; out=$("$HERE/sync.sh" --push child 2>&1) || rc=$?
if [[ $rc -ne 0 ]] && grep -q "refusing to force" <<<"$out"; then
  ok "--push refused to clobber the human-edited branch"
else
  bad "--push did not refuse (rc=$rc)"
fi
[[ "$(git -C "$BARE" rev-parse refs/heads/lineage/sync)" \
   == "$(git -C "$m3" rev-parse HEAD)" ]] \
  && ok "human's commits still on origin/lineage/sync" || bad "human's commits were lost"

echo
if [[ $fail -eq 0 ]]; then echo "smoke test (sync): ALL PASS"; else echo "smoke test (sync): FAILURES"; exit 1; fi
