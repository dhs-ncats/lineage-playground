#!/usr/bin/env bash
# sync.sh — steady-state skeleton sync for a LINEARIZED repo
# (runbook §5/§5a; GitHub-side design: lineage-rework/design.md).
# Rebases origin/<branch> onto the parent skeleton with rerere
# auto-resolving known conflict shapes, verifies, and (with --push,
# interactive) publishes the REVIEW artifacts: the lineage/sync
# branch, its frozen decoy base lineage/sync-base-<sha12>, and the
# PR whose merge triggers ci/lineage-publish.yml (lease-guarded
# force-push of the reviewed SHA to <branch>).
#
# Usage:
#   scripts/sync.sh [options] <repo> ["resume note"]
#
# Options:
#   --parent NAME  Override parent (default: inventory / lineage.yml).
#   --branch NAME  Branch to sync (default: develop, falling back to
#                  origin's HEAD branch).
#   --resume       Continue after a manual stop in work/<repo>-sync/
#                  (fix files, git add, rerun with --resume; an
#                  optional second argument becomes the log note).
#   --fresh        Replace an existing work tree (refused while a
#                  rebase is in progress).
#   --push         Publish the review artifacts for a COMPLETED sync.
#                  Runs verify-sync.sh first and refuses on any
#                  failure. Interactive-only against github.com
#                  remotes; the sandboxed smoke test points ORG_URL
#                  at a local path, which is exempt — nothing reaches
#                  GitHub without a human typing the repo name.
#   --yes          Skip the --push confirmation. REFUSED for cisagov;
#                  exists so playground/sandbox orgs are scriptable.
#
# This script NEVER pushes <branch> itself. Publication happens on
# GitHub when the reviewed PR is merged (merge-to-publish), or
# break-glass by an operator per runbook §8. Under --push it pushes
# only the two lineage/* review branches, with a no-clobber check
# (never force over commits we didn't put there) and a lease.
#
# Exit codes:
#   0  synced (and pushed, with --push)
#   2  paused at a NEW conflict shape — resolve by hand in the work
#      tree, `git add`, then rerun with --resume (rerere records the
#      resolution; the whole fleet reuses it)

source "$(dirname "$0")/common.sh"

# ── args ────────────────────────────────────────────────────────────
PARENT="" BRANCH="develop" RESUME=0 FRESH=0 PUSH=0 YES=0 NOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --parent) PARENT=$2; shift 2;;
    --branch) BRANCH=$2; shift 2;;
    --resume) RESUME=1; shift;;
    --fresh)  FRESH=1; shift;;
    --push)   PUSH=1; shift;;
    --yes)    YES=1; shift;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0;;
    -*)       die "unknown option: $1";;
    *)        if [[ -z "${REPO:-}" ]]; then REPO=$1; else NOTE=$1; fi; shift;;
  esac
done
[[ -n "${REPO:-}" ]] || die "usage: sync.sh [options] <repo>"

WT="$WORK_DIR/$REPO-sync"
LOG="$LOG_DIR/$REPO-sync.log"
RESLOG="$LOG_DIR/$REPO-sync-resolutions.md"
STATE="$WT/.git/SYNC_STATE"

is_github() { [[ "$ORG_URL" == *github.com* ]]; }

save_state() {
  cat > "$STATE" <<EOF
S_BRANCH=$BRANCH
S_PARENT=$PARENT
S_BASE=$S_BASE
S_ONTO=$S_ONTO
S_FROM=$S_FROM
S_STOP=$STOP
S_RERERE_HITS=$RERERE_HITS
S_MANUAL=$MANUAL
EOF
}

load_state() {
  [[ -f "$STATE" ]] || die "no sync state at $STATE — run sync.sh $REPO first"
  # shellcheck disable=SC1090
  source "$STATE"
  BRANCH=$S_BRANCH PARENT=$S_PARENT
  STOP=$S_STOP RERERE_HITS=$S_RERERE_HITS MANUAL=$S_MANUAL
}

# ════ push phase ═════════════════════════════════════════════════════
# Separate entry point: requires a completed, verified sync in the
# work tree. All GitHub traffic lives here, behind the interactive
# gate.
do_push() {
  cd "$WT"
  load_state
  git rev-parse -q --verify develop-sync >/dev/null || die "no develop-sync branch — run sync.sh $REPO first"
  [[ -d .git/rebase-merge || -d .git/rebase-apply ]] && die "rebase in progress — finish it (--resume) before --push"

  say "running sync acceptance checks first…"
  "$ROOT/scripts/verify-sync.sh" "$REPO" || die "verify failed — not pushing"

  local head decoy decoy_sha proxy remote_tip expected
  head=$(git rev-parse develop-sync)
  # REVIEW PROXY model (worklog §49): the PR's head is a single
  # generated commit whose TREE is byte-identical to the rebase
  # result, parented on the develop snapshot. GitHub's Files tab then
  # shows exactly the sync delta (inline review works on the real
  # change), the merge is clean by construction (base = the proxy's
  # parent), and the publish workflow refuses unless the reviewed
  # proxy's tree equals the real branch's tree. The decoy's tip IS
  # the develop snapshot, so the merge commit's first parent
  # cross-checks the lease value in its name.
  decoy="lineage/sync-base-${S_BASE:0:12}"
  decoy_sha=$S_BASE
  proxy=$(git commit-tree 'develop-sync^{tree}' -p "$S_BASE" \
    -m "Lineage sync review proxy: tree of lineage/sync @ ${head:0:12}" \
    -m "Generated for review only — never published. The real rebased
history is on lineage/sync; the publish workflow verifies this
commit's tree is byte-identical to that branch before force-pushing
it to the default branch. Deliberately unsigned.")

  if is_github; then
    echo
    say "about to push review artifacts for $(basename "$ORG_URL")/$REPO:"
    say "  decoy base : $decoy @ ${decoy_sha:0:12} (= origin/$BRANCH snapshot, the lease value)"
    say "  sync branch: lineage/sync → $(git rev-parse --short develop-sync) (force-with-lease)"
    say "  review head: lineage/sync-review → ${proxy:0:7} (1 commit; tree == lineage/sync)"
    say "  then       : open/refresh the PR + post lineage/verify"
    say "  NOT pushed : $BRANCH (publication = merging the PR)"
    if [[ $YES -eq 1 ]]; then
      # --yes exists for sandbox/playground orgs only; pushes to the
      # real org stay human-confirmed (CLAUDE.md hard rule)
      [[ "$ORG_URL" == *cisagov* ]] \
        && die "--yes is refused for cisagov — pushes to the real org are interactive-only"
      say "  (--yes: confirmation skipped for sandbox org)"
    else
      [[ -t 0 ]] || die "--push is interactive-only against GitHub (human go-ahead per repo; --yes exists for sandbox orgs)"
      printf 'Type the repo name to confirm: '
      read -r ans
      [[ "$ans" == "$REPO" ]] || die "confirmation mismatch — aborting, nothing pushed"
    fi
  fi

  # freshness: the decoy must equal origin/<branch> RIGHT NOW, or the
  # lease at publish time would fail anyway — resync instead.
  git fetch -q origin
  [[ "$(git rev-parse "origin/$BRANCH")" == "$S_BASE" ]] \
    || die "origin/$BRANCH moved since this sync started — rerun sync.sh --fresh $REPO"

  # ── no-clobber: never force over commits we did not push ──────────
  remote_tip=$(git ls-remote --heads origin lineage/sync | cut -f1)
  expected=$(cat .git/SYNC_PUSHED 2>/dev/null || true)
  if [[ -z "$expected" && -n "$remote_tip" ]] && is_github && command -v gh >/dev/null; then
    # fresh clone: recover the marker from the open PR's body (the PR's
    # head is the review proxy; pushed-sha records the SYNC branch tip)
    expected=$(gh pr list -R "$(basename "$ORG_URL")/$REPO" --head lineage/sync-review --state open \
      --json body --jq '.[0].body' 2>/dev/null \
      | sed -n 's/.*lineage-sync:pushed-sha=\([0-9a-f]\{40\}\).*/\1/p' | head -1 || true)
  fi
  if [[ -n "$remote_tip" && "$remote_tip" != "$head" ]]; then
    git fetch -q origin refs/heads/lineage/sync
    if git merge-base --is-ancestor "$remote_tip" "origin/$BRANCH" 2>/dev/null; then
      # leftover from a PUBLISHED cycle (its content is already in
      # <branch>, so nothing unique is lost) — safe to replace
      say "origin/lineage/sync is stale from a published cycle — replacing"
    elif [[ -z "$expected" ]]; then
      die "origin/lineage/sync exists ($remote_tip) and no pushed-sha marker is recoverable — refusing to force over it; inspect the branch (another operator? a human edit?) and delete it to proceed"
    elif [[ "$remote_tip" != "$expected" ]]; then
      die "origin/lineage/sync has commits we didn't push (tip $remote_tip ≠ marker $expected) — a human edited the branch; coordinate with them instead of clobbering (design.md: etiquette)"
    fi
  fi

  # ── decoy base: create (or confirm) the merge sink ─────────────────
  local decoy_tip
  decoy_tip=$(git ls-remote --heads origin "$decoy" | cut -f1)
  if [[ -z "$decoy_tip" ]]; then
    git push -q origin "$decoy_sha:refs/heads/$decoy"
    say "pushed decoy base $decoy @ ${decoy_sha:0:12}"
  elif [[ "$decoy_tip" != "$decoy_sha" ]]; then
    die "origin/$decoy exists at $decoy_tip ≠ $decoy_sha — stale decoy; delete it and rerun"
  fi

  # ── sync branch: plain push when new, lease against observed tip ──
  if [[ -z "$remote_tip" ]]; then
    git push -q origin develop-sync:refs/heads/lineage/sync
  elif [[ "$remote_tip" != "$head" ]]; then
    git push -q --force-with-lease=refs/heads/lineage/sync:"$remote_tip" \
      origin develop-sync:refs/heads/lineage/sync
  fi
  printf '%s\n' "$head" > .git/SYNC_PUSHED
  say "pushed lineage/sync @ $(git rev-parse --short develop-sync)"

  # ── review proxy: a generated artifact, machine-owned — regenerated
  #    (and force-pushed) on every refresh; humans resolve on the SYNC
  #    branch, never here ─────────────────────────────────────────────
  git push -qf origin "$proxy:refs/heads/lineage/sync-review"
  say "pushed lineage/sync-review @ ${proxy:0:7}"

  if ! is_github || ! command -v gh >/dev/null; then
    say "non-GitHub remote (or no gh) — skipping PR/status steps"
    return 0
  fi

  # ── PR + status (GitHub only) ──────────────────────────────────────
  local gr body pr
  gr="$(basename "$ORG_URL")/$REPO"
  body=$(mktemp)
  {
    echo "## Lineage sync: rebase onto \`$PARENT\` @ \`$(git rev-parse --short "upstream/$BRANCH")\`"
    echo
    echo "**Merging this PR publishes.** The *Files changed* tab IS the sync"
    echo "delta — exactly what will change on \`$BRANCH\`. The head is a"
    echo "generated REVIEW PROXY (one commit whose tree is byte-identical to"
    echo "the real rebased history on \`lineage/sync\`); the base (\`$decoy\`) is"
    echo "a decoy snapshot of \`$BRANCH\` that absorbs the merge. On merge,"
    echo "\`lineage-publish.yml\` verifies the reviewed tree equals"
    echo "\`lineage/sync\`, then force-pushes THAT branch (the real, signed,"
    echo "per-commit history) to \`$BRANCH\` with a lease against the snapshot —"
    echo "if anything reached \`$BRANCH\` mid-review, publish refuses instead of"
    echo "overwriting it. See \`lineage-rework/design.md\`."
    echo
    echo "- Review here as usual; the commits being published (with their real"
    echo "  authorship) are on \`lineage/sync\`:"
    echo
    echo '```'
    echo "git fetch origin && git log origin/$BRANCH..origin/lineage/sync"
    echo '```'
    echo
    echo "- Never push to \`lineage/sync-review\` — it is regenerated on every"
    echo "  refresh. Conflict resolutions happen on \`lineage/sync\`."
    echo
    echo "Delta vs \`$BRANCH\`: $(git diff --shortstat "$S_BASE"..develop-sync | sed 's/^ *//')"
    echo "Upstream commits synced: $(git rev-list --topo-order --count "$S_BASE..upstream/$BRANCH")"
    echo "Resolution log: \`campaign/logs/$REPO-sync-resolutions.md\` (stops=$STOP rerere=$RERERE_HITS manual=$MANUAL)"
    echo
    echo "<!-- lineage-sync:pushed-sha=$head -->"
    echo "<!-- lineage-sync:base=$S_BASE -->"
    echo "<!-- lineage-sync:onto=$S_ONTO -->"
  } > "$body"

  pr=$(gh pr list -R "$gr" --head lineage/sync-review --state open --json number --jq '.[0].number' 2>/dev/null || true)
  if [[ -n "$pr" ]]; then
    gh pr edit "$pr" -R "$gr" --base "$decoy" --body-file "$body" >/dev/null
    say "refreshed PR #$pr (base retargeted to $decoy)"
  else
    gh pr create -R "$gr" --base "$decoy" --head lineage/sync-review \
      --title "Lineage sync: $PARENT @ $(git rev-parse --short "upstream/$BRANCH")" \
      --body-file "$body"
  fi
  rm -f "$body"

  gh api "repos/$gr/statuses/$proxy" -f state=success -f context=lineage/verify \
    -f description="sync acceptance checks 7/7 (verify-sync.sh, local)" >/dev/null
  say "posted lineage/verify=success on ${proxy:0:12}"

  # retire decoys from superseded cycles
  while read -r _ ref; do
    [[ "$ref" == "refs/heads/$decoy" || -z "$ref" ]] && continue
    git push -q origin ":$ref" && say "deleted stale decoy ${ref#refs/heads/}"
  done < <(git ls-remote --heads origin 'lineage/sync-base-*')

  say "next: review + approve on GitHub; merging publishes $BRANCH"
}

if [[ $PUSH -eq 1 ]]; then
  [[ -d "$WT/.git" ]] || die "no work tree at $WT — run sync.sh $REPO first"
  do_push
  exit 0
fi

# ════ sync phase ═════════════════════════════════════════════════════
STOP=0 RERERE_HITS=0 MANUAL=0 S_BASE="" S_ONTO="" S_FROM=""

if [[ $RESUME -eq 1 ]]; then
  [[ -d "$WT/.git" ]] || die "--resume but no work tree at $WT"
else
  if [[ -d "$WT" ]]; then
    if [[ $FRESH -eq 1 ]]; then
      [[ -d "$WT/.git/rebase-merge" || -d "$WT/.git/rebase-apply" ]] \
        && die "rebase in progress in $WT — finish it (--resume) before --fresh"
      rm -rf "$WT"
    else
      die "work/$REPO-sync already exists — use --resume (mid-stop), --fresh (restart), or --push (publish)"
    fi
  fi
  say "cloning $ORG_URL/$REPO.git → $WT"
  git clone -q "$ORG_URL/$REPO.git" "$WT"
fi
prep_repo "$WT"
[[ $RESUME -eq 1 ]] || link_cache "$WT"

cd "$WT"
exec > >(tee -a "$LOG") 2>&1
say "sync $REPO (branch=$BRANCH resume=$RESUME)"

if [[ $RESUME -eq 1 ]]; then
  load_state
else
  # branch fallback, parent, upstream — as linearize.sh
  if ! git rev-parse -q --verify "origin/$BRANCH" >/dev/null; then
    fallback=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||')
    say "no origin/$BRANCH — using origin HEAD branch: $fallback"
    BRANCH=$fallback
  fi
  if [[ -z "$PARENT" ]]; then
    PARENT=$(parent_of "$REPO") || die "could not determine parent for $REPO (pass --parent)"
  fi
  [[ "$PARENT" != "$REPO" ]] || die "$REPO's parent resolved to itself"
  say "parent skeleton: $PARENT"
  git remote get-url upstream >/dev/null 2>&1 \
    || git remote add upstream "$ORG_URL/$PARENT.git"
  git fetch -q upstream
fi

UPSTREAM_REF="upstream/$BRANCH"
git rev-parse -q --verify "$UPSTREAM_REF" >/dev/null \
  || UPSTREAM_REF="upstream/$(git remote show upstream | sed -n 's/.*HEAD branch: //p')"

if [[ $RESUME -eq 0 ]]; then
  S_BASE=$(git rev-parse "origin/$BRANCH")
  S_ONTO=$(git rev-parse "$UPSTREAM_REF")
  say "upstream: $UPSTREAM_REF ($(git rev-parse --short "$UPSTREAM_REF"))  base: origin/$BRANCH (${S_BASE:0:12})"

  # exact range walks on skewed linear history need a commit-graph
  # AND --topo-order (worklog §47)
  git commit-graph write --reachable 2>/dev/null || true

  git merge-base "origin/$BRANCH" "$UPSTREAM_REF" >/dev/null 2>&1 \
    || die "$REPO shares no history with $PARENT — wrong parent?"
  if git merge-base --is-ancestor "$UPSTREAM_REF" "origin/$BRANCH"; then
    say "already in sync: origin/$BRANCH contains $UPSTREAM_REF — nothing to do"
    # this run's clone holds no state — remove it so the next real
    # sync starts clean instead of demanding --fresh
    cd "$ROOT" && rm -rf "$WT"
    exit 0
  fi
  # sync presumes the linear model: a braid above upstream means this
  # repo was never linearized (or regressed — see no-upstream-merges.yml)
  merges=$(git rev-list --topo-order --merges "$(git merge-base "origin/$BRANCH" "$UPSTREAM_REF")..origin/$BRANCH" | wc -l)
  [[ "$merges" -eq 0 ]] \
    || die "$merges merge commit(s) above upstream — $REPO isn't linearized; run linearize.sh first (runbook §4)"

  # signing preflight — same policy as linearize.sh (worklog §31)
  if [[ "$(git config --type=bool --get commit.gpgsign 2>/dev/null || echo false)" == "true" ]]; then
    git switch -q --detach
    git commit -q --allow-empty -m "signing preflight" \
      || die "commit.gpgsign=true but signing FAILED (key/agent/pinentry?) — fix signing, then rerun with --fresh"
    git cat-file commit HEAD | grep -q '^gpgsig' \
      || die "commit.gpgsign=true but the test commit came out UNSIGNED — check gpg.format / user.signingkey"
    git switch -q -
  else
    warn "commit signing is OFF — replayed commits will be unsigned and verify-sync will fail them (team policy, worklog §31)"
  fi

  n_up=$(git rev-list --topo-order --count "origin/$BRANCH..$UPSTREAM_REF")
  # The ONLY-OUR-DELTA rule (worklog §47): a parent publish rewrites
  # every inherited SHA, so a plain `rebase upstream/develop` would
  # replay the repo's ENTIRE inherited stack — spurious conflicts from
  # inherited add/remove pairs, and unverifiable drops. The previous
  # publish recorded the parent tip it synced onto as the lineage/base
  # tag; rebase --onto from there replays only this repo's own
  # commits. No tag (first sync, or tier-1 where the root is never
  # rewritten) → full rebase, which is then equivalent.
  git fetch -q origin '+refs/tags/lineage/base:refs/tags/lineage/base' 2>/dev/null || true
  REBASE_FROM="$UPSTREAM_REF"
  if git rev-parse -q --verify 'refs/tags/lineage/base^{commit}' >/dev/null; then
    base_tag=$(git rev-parse 'refs/tags/lineage/base^{commit}')
    if git merge-base --is-ancestor "$base_tag" "origin/$BRANCH"; then
      REBASE_FROM=$base_tag
      say "lineage/base tag found (${REBASE_FROM:0:12}) — replaying only this repo's own delta"
    else
      warn "lineage/base tag (${base_tag:0:12}) is not an ancestor of origin/$BRANCH — stale; falling back to a full rebase"
    fi
  fi
  n_down=$(git rev-list --topo-order --count "$REBASE_FROM..origin/$BRANCH")
  say "replaying $n_down downstream commits onto $n_up new upstream commits"

  : > "$RESLOG"
  {
    echo "# Sync resolution log — $REPO ($(date -I))"
    echo
    echo "- Parent: \`$PARENT\` @ \`$(git rev-parse --short "$UPSTREAM_REF")\`"
    echo "- Base: \`origin/$BRANCH\` @ \`${S_BASE:0:12}\` (replay from \`${REBASE_FROM:0:12}\`)"
    echo "- Downstream commits replayed: $n_down (over $n_up new upstream)"
    echo
    echo "| # | Replaying | Files | Handled by | Notes |"
    echo "|--:|---|---|---|---|"
  } >> "$RESLOG"

  S_FROM=$REBASE_FROM
  save_state
  git switch -q -C develop-sync "origin/$BRANCH"
  git rebase --committer-date-is-author-date --onto "$UPSTREAM_REF" "$REBASE_FROM" >/dev/null 2>&1 \
    && say "rebase completed with zero stops"
fi

# ── stop loop: rerere resolves or we pause (no forced modes here —
#    a NEW shape in steady state deserves a human; the resolution is
#    then cached for the fleet) ───────────────────────────────────────
rebase_dir() { [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; }

if [[ $RESUME -eq 1 ]] && rebase_dir; then
  if [[ -f .git/SYNC_STOP ]]; then
    STOP=$(cat .git/SYNC_STOP)
    [[ -z "$(git ls-files -u)" ]] || die "unmerged paths remain — resolve and \`git add\` them, then rerun with --resume"
    cur=$(git rev-parse --short REBASE_HEAD 2>/dev/null || echo "?")
    subj=$(git log -1 --pretty=%s REBASE_HEAD 2>/dev/null || echo "?")
    files_disp=$(git diff --cached --name-only | tr '\n' ' ' | sed 's/ *$//')
    MANUAL=$((MANUAL+1))
    printf '| %d | `%s` %s | %s | %s | %s |\n' \
      "$STOP" "$cur" "${subj//|/\\|}" "${files_disp// /<br>}" "**manual**" "${NOTE//|/\\|}" >> "$RESLOG"
    rm -f .git/SYNC_STOP
    save_state
  fi
  if ! GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; then
    if git diff --cached --quiet && [[ -z "$(git ls-files -u)" ]]; then
      git rebase --skip >/dev/null 2>&1 || true
    fi
  fi
fi

SPIN=0 last_spin=""
while rebase_dir; do
  STOP=$((STOP+1))
  cur=$(git rev-parse --short REBASE_HEAD 2>/dev/null || echo "?")
  subj=$(git log -1 --pretty=%s REBASE_HEAD 2>/dev/null || echo "?")

  # anti-spin guard, as linearize.sh (worklog §33)
  t=.git/rebase-merge/git-rebase-todo; [[ -f "$t" ]] || t=/dev/null
  spin_key="$cur:$(wc -l < "$t")"
  if [[ "$spin_key" == "$last_spin" ]]; then
    SPIN=$((SPIN+1))
    if [[ $SPIN -ge 3 ]]; then
      warn "rebase is not advancing (still replaying $cur); git says:"
      GIT_EDITOR=true git rebase --continue 2>&1 | sed 's/^/    /' || true
      save_state
      die "stuck at stop $STOP — inspect $WT (git status), fix, then rerun with --resume"
    fi
  else
    SPIN=0
  fi
  last_spin=$spin_key

  unmerged=$(git ls-files -u | cut -f2 | sort -u)
  remaining=$(git rerere remaining 2>/dev/null || true)
  files_disp=$(echo "$unmerged" | tr '\n' ' ' | sed 's/ *$//')

  if [[ -z "$unmerged" ]]; then
    handled="rerere (staged)"
    RERERE_HITS=$((RERERE_HITS+1))
  elif [[ -z "$remaining" ]]; then
    handled="rerere"
    RERERE_HITS=$((RERERE_HITS+1))
    for f in $unmerged; do
      if [[ -e "$f" ]]; then git add "$f"; else git rm -q "$f"; fi
    done
  else
    MANUAL=$((MANUAL+1))
    say "stop $STOP: NEW conflict shape — $files_disp"
    say "  replaying: $cur $subj"
    say "  resolve:   edit the file(s) in $WT, then git -C $WT add <files>"
    say "  then:      $0 --resume $REPO \"note: what you chose and why\""
    echo "$STOP" > .git/SYNC_STOP
    save_state
    exit 2
  fi

  printf '| %d | `%s` %s | %s | %s | |\n' \
    "$STOP" "$cur" "${subj//|/\\|}" "${files_disp// /<br>}" "$handled" >> "$RESLOG"
  save_state

  if ! GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; then
    if git diff --cached --quiet && [[ -z "$(git ls-files -u)" ]]; then
      git rebase --skip >/dev/null 2>&1 || true
    fi
  fi
done

save_state
{
  echo
  echo "**Totals:** stops=$STOP · rerere=$RERERE_HITS · manual=$MANUAL"
} >> "$RESLOG"
say "rebase complete: stops=$STOP rerere=$RERERE_HITS manual=$MANUAL"
say "develop-sync = $(git rev-parse --short develop-sync)"

# commit new cache entries — sync always runs linked to the shared
# cache (explicit-path staging; worklog §27/§37)
if [[ -L "$WT/.git/rr-cache" ]]; then
  find "$CACHE_DIR" -name .git -prune -o -type f ! -name 'thisimage*' -print0 \
    | xargs -0 git -C "$CACHE_DIR" add --
  if ! git -C "$CACHE_DIR" diff --cached --quiet; then
    git -C "$CACHE_DIR" commit -q -m "Resolutions from $REPO sync (stops=$STOP)"
    say "committed rr-cache updates"
    commit_signed "$CACHE_DIR" HEAD \
      || warn "cache commit is UNSIGNED — cache-push.sh will refuse it (resign.sh --cache-unpushed; worklog §39)"
  fi
fi

say "verifying…"
"$ROOT/scripts/verify-sync.sh" "$REPO" || die "verify failed — fix before --push (log: $RESLOG)"

say "logs: $LOG"
say "next: scripts/sync.sh --push $REPO   (review PR; merging publishes)"
