#!/usr/bin/env bash
# linearize.sh — one-time linearizing rebase of a skeleton descendant
# onto its parent, per runbook §4/§7. Local only; never pushes.
#
# Usage:
#   scripts/linearize.sh [options] <repo>
#
# Options:
#   --parent NAME    Override parent (default: read from lineage.yml /
#                    campaign/downstream-inventory.json).
#   --branch NAME    Branch to linearize (default: develop, falling
#                    back to origin's HEAD branch if develop is absent).
#   --final-safe     At each stop, for each conflicting file that NO
#                    later commit in the rebase todo touches, take
#                    archive/pre-linearization:<file>. This is a
#                    provably-correct resolution given the invariant
#                    (end state == archive). Modify/delete conflicts
#                    are handled (theirs re-adds; drop honors delete).
#                    Content conflicts with later touches still
#                    pause.
#   --final-force    Like --final-safe, but resolve EVERY remaining
#                    conflict by taking archive/pre-linearization's
#                    version. Fully automatic — the campaign default
#                    (worklog §24). Tradeoff: intermediate commits
#                    carry the FINAL form of the conflicting file
#                    (its history "jumps ahead" at the first
#                    conflict). The commit's other changes are
#                    preserved; original history survives at
#                    archive/pre-linearization.
#
# End state == archive is guaranteed by the RECONCILIATION step in
# every mode except --auto-resolve: replaying only non-merge commits
# loses changes that existed solely in merge commits, and 3-way
# replay can drift without conflicting (worklog §28). After the
# rebase, any remaining difference vs archive is restored in one
# final self-documenting commit whose diff is the audit record.
#   --auto-resolve   At each stop, if rerere didn't fully resolve,
#                    take THEIRS and continue. FOR MEASUREMENT ONLY —
#                    the resulting develop-linear is not publishable.
#                    Every such stop is flagged in the resolution log.
#   --resume         Continue an in-progress rebase in work/<repo>/
#                    instead of re-cloning. Mode, branch, and stop
#                    counters are restored from .git/LINEARIZE_STATE;
#                    mode flags passed alongside --resume are ignored
#                    (to change mode, start the repo over).
#   --allow-stale    Proceed even when origin/<branch> is not caught
#                    up with the parent (§4a invariant). Refused for
#                    --final-safe/--final-force, whose archive-based
#                    resolutions would revert upstream changes.
#   --no-train       Skip rerere-train.sh (use only what's already in
#                    the shared cache).
#
# rr-cache handling: rerere-train output is always committed to the
# SHARED cache first (those are real historical resolutions — they
# make future syncs smooth). --auto-resolve and --final-force then
# detach to an ISOLATED copy for the rebase itself, so their
# synthetic "jump to final" resolutions never pollute the shared
# cache.
#
# Outputs:
#   work/<repo>/                  the working clone; develop-linear
#                                 branch; archive/pre-linearization tag
#   campaign/logs/<repo>.log      full transcript
#   campaign/logs/<repo>-resolutions.md
#                                 one entry per rebase stop, for review
#   rr-cache/                     new fingerprints committed
#
# Exit codes:
#   0  rebase completed (with or without --auto-resolve)
#   2  rebase paused for manual resolution (rerun with --resume after
#      fixing, or use --auto-resolve for a measurement pass)

source "$(dirname "$0")/common.sh"

# ── args ────────────────────────────────────────────────────────────
PARENT="" BRANCH="develop" AUTO=0 RESUME=0 TRAIN=1 FINAL_SAFE=0 FINAL_FORCE=0 ALLOW_STALE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --parent)       PARENT=$2; shift 2;;
    --branch)       BRANCH=$2; shift 2;;
    --auto-resolve) AUTO=1; shift;;
    --final-safe)   FINAL_SAFE=1; shift;;
    --final-force)  FINAL_SAFE=1; FINAL_FORCE=1; shift;;
    --resume)       RESUME=1; shift;;
    --allow-stale)  ALLOW_STALE=1; shift;;
    --no-train)     TRAIN=0; shift;;
    -h|--help)      sed -n '2,/^$/p' "$0"; exit 0;;
    -*)             die "unknown option: $1";;
    *)              REPO=$1; shift;;
  esac
done
[[ -n "${REPO:-}" ]] || die "usage: linearize.sh [options] <repo>"

WT="$WORK_DIR/$REPO"
LOG="$LOG_DIR/$REPO.log"
RESLOG="$LOG_DIR/$REPO-resolutions.md"
STATE="$WT/.git/LINEARIZE_STATE"
FILEMAP="$WT/.git/LINEARIZE_FILEMAP"

# tee everything from here on
exec > >(tee -a "$LOG") 2>&1
say "linearize $REPO (branch=$BRANCH auto=$AUTO final_safe=$FINAL_SAFE final_force=$FINAL_FORCE resume=$RESUME)"

# ── clone / resume ──────────────────────────────────────────────────
if [[ $RESUME -eq 1 ]]; then
  [[ -d "$WT/.git" ]] || die "--resume but no work tree at $WT"
else
  if [[ -d "$WT" ]]; then
    die "work/$REPO already exists — use --resume, or remove it"
  fi
  say "cloning $ORG_URL/$REPO.git → $WT"
  git clone -q "$ORG_URL/$REPO.git" "$WT"
fi
prep_repo "$WT"
# Always start linked to the shared cache so rerere-train lands there;
# isolated modes detach AFTER training (below).
[[ $RESUME -eq 1 ]] || link_cache "$WT"

cd "$WT"

# ── run state (mode, branch, counters survive pauses and crashes) ───
STOP=0 RERERE_HITS=0 MANUAL=0 FINAL_HITS=0
save_state() {
  cat > "$STATE" <<EOF
S_AUTO=$AUTO
S_FINAL_SAFE=$FINAL_SAFE
S_FINAL_FORCE=$FINAL_FORCE
S_BRANCH=$BRANCH
S_PARENT=$PARENT
S_STOP=$STOP
S_RERERE_HITS=$RERERE_HITS
S_MANUAL=$MANUAL
S_FINAL_HITS=$FINAL_HITS
EOF
}
if [[ $RESUME -eq 1 && -f "$STATE" ]]; then
  cli_mode="$AUTO$FINAL_SAFE$FINAL_FORCE"
  # shellcheck disable=SC1090
  source "$STATE"
  AUTO=$S_AUTO FINAL_SAFE=$S_FINAL_SAFE FINAL_FORCE=$S_FINAL_FORCE
  BRANCH=$S_BRANCH
  [[ -n "$PARENT" ]] || PARENT=${S_PARENT:-}
  STOP=$S_STOP RERERE_HITS=$S_RERERE_HITS MANUAL=$S_MANUAL FINAL_HITS=$S_FINAL_HITS
  [[ "$cli_mode" != "000" && "$cli_mode" != "$AUTO$FINAL_SAFE$FINAL_FORCE" ]] \
    && warn "mode flags passed with --resume are ignored; run continues as started (see $STATE)"
fi

# ── signing preflight ───────────────────────────────────────────────
# Team policy: signed commits everywhere (worklog §31). If signing is
# enabled, prove it works headlessly NOW — a broken key/agent/pinentry
# should fail in seconds, not wedge a 400-commit rebase. If it's off,
# warn: publish.sh will refuse unsigned history.
if [[ $RESUME -eq 0 ]]; then
  if [[ "$(git config --type=bool --get commit.gpgsign 2>/dev/null || echo false)" == "true" ]]; then
    git switch -q --detach
    git commit -q --allow-empty -m "signing preflight" \
      || die "commit.gpgsign=true but signing FAILED (key/agent/pinentry?) — fix signing, then remove work/$REPO and rerun"
    git cat-file commit HEAD | grep -q '^gpgsig' \
      || die "commit.gpgsign=true but the test commit came out UNSIGNED — check gpg.format / user.signingkey"
    git switch -q -
    say "signing preflight OK (replayed commits will be signed)"
  else
    warn "commit signing is OFF — commits will be unsigned and publish.sh will refuse them (team policy, worklog §31)"
  fi
fi

# ── branch (fall back to origin's HEAD branch, e.g. main) ───────────
if [[ $RESUME -eq 0 ]] && ! git rev-parse -q --verify "origin/$BRANCH" >/dev/null; then
  fallback=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||')
  say "no origin/$BRANCH — using origin HEAD branch: $fallback"
  BRANCH=$fallback
fi

# ── determine parent ────────────────────────────────────────────────
if [[ -z "$PARENT" ]]; then
  PARENT=$(parent_of "$REPO") || die "could not determine parent for $REPO (pass --parent)"
fi
[[ "$PARENT" != "$REPO" ]] || die "$REPO's parent resolved to itself"
say "parent skeleton: $PARENT"

git remote get-url upstream >/dev/null 2>&1 \
  || git remote add upstream "$ORG_URL/$PARENT.git"
say "fetching upstream ($PARENT)"
git fetch -q upstream

UPSTREAM_REF="upstream/$BRANCH"
git rev-parse -q --verify "$UPSTREAM_REF" >/dev/null \
  || UPSTREAM_REF="upstream/$(git remote show upstream | sed -n 's/.*HEAD branch: //p')"
say "upstream ref: $UPSTREAM_REF ($(git rev-parse --short "$UPSTREAM_REF"))"

# ── §4a invariant gate ──────────────────────────────────────────────
# final-safe/final-force take archive:<file> at conflicts; that is
# only correct when origin/<branch> is fully caught up with the
# parent. Otherwise those resolutions would silently REVERT upstream
# changes, and the empty-diff oracle can't catch it.
if [[ $RESUME -eq 0 ]]; then
  CAUGHT_UP=0
  if [[ "$(git merge-base "origin/$BRANCH" "$UPSTREAM_REF" 2>/dev/null || true)" \
        == "$(git rev-parse "$UPSTREAM_REF")" ]]; then
    CAUGHT_UP=1
    say "invariant holds: origin/$BRANCH is fully caught up with $UPSTREAM_REF"
  else
    # Tier-2 case (runbook §7): the parent was linearized IN PLACE, so
    # its tip was rewritten and ancestry can never hold. The
    # equivalent invariant: this repo is caught up with the parent's
    # archive/pre-linearization tag AND the parent's linear tip is
    # tree-identical to it (the parent's own §4a oracle). The tag
    # must be fetched explicitly — it points at history no longer
    # reachable from the parent's branches, so tag auto-following
    # never brings it in.
    git fetch -q upstream \
      '+refs/tags/archive/pre-linearization:refs/tags/upstream-archive/pre-linearization' \
      2>/dev/null || true
    UARCH=upstream-archive/pre-linearization
    if git rev-parse -q --verify "$UARCH^{commit}" >/dev/null \
       && [[ "$(git merge-base "origin/$BRANCH" "$UARCH" 2>/dev/null || true)" \
             == "$(git rev-parse "$UARCH^{commit}")" ]] \
       && [[ "$(git rev-parse "$UARCH^{tree}")" \
             == "$(git rev-parse "$UPSTREAM_REF^{tree}")" ]]; then
      CAUGHT_UP=1
      say "invariant holds via the parent's archive tag: the parent was linearized in place (tree-identical tip) and origin/$BRANCH is caught up with its pre-linearization history"
    fi
  fi
  if [[ $CAUGHT_UP -eq 1 ]]; then
    say "  → diff vs archive/pre-linearization MUST be empty at verify"
  elif [[ $FINAL_SAFE -eq 1 ]]; then
    die "invariant FAILED: $REPO@$BRANCH is missing commits that already landed on $PARENT (${UPSTREAM_REF}). This does NOT mean the parent needs linearizing — the lineage root never is. Merge $REPO's open Lineage PR (or manually merge $PARENT into $BRANCH) so the repo is caught up, then remove work/$REPO and rerun. Runbook §4a."
  elif [[ $ALLOW_STALE -eq 1 || $AUTO -eq 1 ]]; then
    warn "upstream is ahead of origin/$BRANCH — verify's diff will include upstream-only changes"
  else
    die "origin/$BRANCH is not caught up with $UPSTREAM_REF (runbook §4a). Pass --allow-stale to proceed anyway."
  fi
fi

# ── seed cache from this repo's own history ─────────────────────────
if [[ $RESUME -eq 0 && $TRAIN -eq 1 ]]; then
  # Idempotency stamp (worklog §30): training replays every historical
  # merge; when the cache already holds a resolution, rerere's reuse
  # path records nothing new and just drops a `thisimage` scratch file
  # into the entry dir (ignored via the cache repo's .gitignore). Skip
  # the whole replay when this repo's tip is unchanged since the last
  # training run.
  TRAIN_TIP=$(git rev-parse "origin/$BRANCH")
  STAMP="$CACHE_DIR/trained/$REPO"
  if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$TRAIN_TIP" ]]; then
    say "rr-cache already trained from $REPO @ ${TRAIN_TIP:0:7} — skipping (rm $STAMP to retrain)"
  else
    find_rerere_train
    say "training rr-cache from $BRANCH history via $RERERE_TRAIN"
    before=$(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name .git ! -name trained | wc -l)
    # rerere-train hard-resets; we're in a fresh clone so that's fine.
    sh "$RERERE_TRAIN" "origin/$BRANCH" 2>&1 | grep -E '^Learning' || true
    after=$(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name .git ! -name trained | wc -l)
    say "rr-cache: $before → $after entries"
    if [[ "$after" -eq "$before" ]]; then
      warn "training recorded no new entries — fine when another repo already covered this history; NOT fine on a fresh cache (worklog §32)"
    fi
    # stamp only after training succeeded — a crash mid-train retrains
    mkdir -p "$CACHE_DIR/trained"
    printf '%s\n' "$TRAIN_TIP" > "$STAMP"
    # Trained entries are real historical resolutions — commit them to
    # the shared cache before any isolated mode detaches from it.
    # Stage by EXPLICIT PATH from find: on git 2.54/macOS both
    # `status --porcelain` (worklog §27) and `git add -A`'s untracked
    # walk (worklog §37) have missed brand-new files at script speed;
    # find demonstrably sees them.
    find "$CACHE_DIR" -name .git -prune -o -type f ! -name 'thisimage*' -print0 \
      | xargs -0 git -C "$CACHE_DIR" add --
    if ! git -C "$CACHE_DIR" diff --cached --quiet; then
      git -C "$CACHE_DIR" commit -q -m "rerere-train from $REPO history"
      commit_signed "$CACHE_DIR" HEAD \
        || warn "cache commit is UNSIGNED — cache-push.sh will refuse it (resign.sh --cache-unpushed before pushing; worklog §39)"
    fi
    # never silent again: the stamp must be tracked after this block
    git -C "$CACHE_DIR" ls-files --error-unmatch "trained/$REPO" >/dev/null 2>&1 \
      || die "cache commit did not pick up trained/$REPO (worklog §37) — rerun after checking the cache repo"
  fi
fi

# ── isolated modes detach from the shared cache for the rebase ──────
if [[ $RESUME -eq 0 && ( $AUTO -eq 1 || $FINAL_FORCE -eq 1 ) ]]; then
  say "detaching to ISOLATED rr-cache (forced resolutions are not written back to shared)"
  rm -f "$WT/.git/rr-cache"
  mkdir -p "$WT/.git/rr-cache"
  find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name .git ! -name trained -exec cp -r {} "$WT/.git/rr-cache/" \;
fi

# ── archive tag + start rebase ──────────────────────────────────────
if [[ $RESUME -eq 0 ]]; then
  git switch -q -C "$BRANCH" "origin/$BRANCH"
  git tag -f archive/pre-linearization "$BRANCH"
  say "tagged archive/pre-linearization = $(git rev-parse --short archive/pre-linearization)"

  n_replay=$(git rev-list --topo-order --no-merges "$UPSTREAM_REF".."$BRANCH" | wc -l)
  say "replaying $n_replay non-merge commits onto $UPSTREAM_REF"

  # commit→files map: later_touches() reads this instead of running
  # `git show` per todo entry per stop (was O(todo × files) per stop)
  git log --topo-order --no-merges --format='%x01%H' --name-only "$UPSTREAM_REF".."$BRANCH" \
    | awk '/^\x01/{sha=substr($0,2);next} NF{print sha "\t" $0}' > "$FILEMAP"

  : > "$RESLOG"
  {
    echo "# Resolution log — $REPO"
    echo
    echo "- Parent: \`$PARENT\` @ \`$(git rev-parse --short "$UPSTREAM_REF")\`"
    echo "- Archive tag: \`$(git rev-parse --short archive/pre-linearization)\`"
    echo "- Commits replayed: $n_replay"
    [[ $AUTO -eq 1 ]] && echo "- **MEASUREMENT RUN** (\`--auto-resolve\`): non-rerere stops were force-resolved with THEIRS. Do not publish this branch."
    echo
    echo "| # | Replaying | Files | Handled by | Notes |"
    echo "|--:|---|---|---|---|"
  } >> "$RESLOG"

  save_state
  git switch -q -C develop-linear "$BRANCH"
  # --committer-date-is-author-date: keep each replayed commit's
  # timestamps instead of stamping them all with today. Recorded in
  # the rebase state, so every later --continue inherits it. No git
  # config equivalent exists (worklog §22).
  git rebase --committer-date-is-author-date "$UPSTREAM_REF" >/dev/null 2>&1 && {
    say "rebase completed with zero stops"
    finish=1
  }
fi

# ── stop loop ───────────────────────────────────────────────────────
rebase_dir() { [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; }
todo_file() {
  [[ -f .git/rebase-merge/git-rebase-todo ]] && echo .git/rebase-merge/git-rebase-todo
}
later_touches() {
  local f=$1 t; t=$(todo_file) || return 0
  if [[ ! -s "$FILEMAP" ]]; then
    git log --topo-order --no-merges --format='%x01%H' --name-only "$UPSTREAM_REF".."$BRANCH" \
      | awk '/^\x01/{sha=substr($0,2);next} NF{print sha "\t" $0}' > "$FILEMAP"
  fi
  # todo shas are abbreviated; match them as prefixes of the map's
  # full shas
  awk -v f="$f" '
    NR==FNR { i=index($0,"\t"); if (i && substr($0,i+1)==f) shas[substr($0,1,i-1)]=1; next }
    $1=="pick" || $1=="p" { for (s in shas) if (index(s,$2)==1) { print s; break } }
  ' "$FILEMAP" "$t"
}
apply_final() {
  local f=$1
  if git cat-file -e "archive/pre-linearization:$f" 2>/dev/null; then
    mkdir -p "$(dirname "$f")"
    git show "archive/pre-linearization:$f" > "$f"
    git add -- "$f"
  else
    rm -f -- "$f"
    git add -- "$f" 2>/dev/null || true
    git rm -q -f --cached -- "$f" 2>/dev/null || true
  fi
}

if [[ $RESUME -eq 1 && ! -f .git/LINEARIZE_STOP ]] && rebase_dir; then
  # resumed mid-rebase without a paused-stop marker (e.g., after a
  # crash) — try to continue if the current stop is already staged.
  if [[ -z "$(git ls-files -u)" ]]; then
    say "resume: current stop already staged; continuing"
    if ! GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; then
      if git diff --cached --quiet && [[ -z "$(git ls-files -u)" ]]; then
        git rebase --skip >/dev/null 2>&1 || true
      fi
    fi
  fi
  if [[ ! -f "$STATE" ]]; then
    # legacy tree without a state file — recover counters from the log
    STOP=$(grep -cE '^\| [0-9]+ \|' "$RESLOG" 2>/dev/null || echo 0)
    RERERE_HITS=$(grep -c '| rerere' "$RESLOG" 2>/dev/null || true)
    MANUAL=$(grep -c '| \*\*manual\*\*' "$RESLOG" 2>/dev/null || true)
    FINAL_HITS=$(grep -c '| final' "$RESLOG" 2>/dev/null || true)
  fi
elif [[ $RESUME -eq 1 && -f .git/LINEARIZE_STOP ]]; then
  STOP=$(cat .git/LINEARIZE_STOP)
  say "resuming after manual stop $STOP"
  cur=$(git rev-parse --short REBASE_HEAD 2>/dev/null || echo "?")
  subj=$(git log -1 --pretty=%s REBASE_HEAD 2>/dev/null || echo "?")
  # Log the just-completed manual stop with the resolver's note.
  note=""
  [[ -f .git/LINEARIZE_NOTE ]] && note=$(tr '\n' ' ' < .git/LINEARIZE_NOTE)
  files_disp=$(git diff --cached --name-only | tr '\n' ' ' | sed 's/ *$//')
  MANUAL=$((MANUAL+1))
  printf '| %d | `%s` %s | %s | %s | %s |\n' \
    "$STOP" "$cur" "${subj//|/\\|}" "${files_disp// /<br>}" "**manual**" "${note//|/\\|}" >> "$RESLOG"
  rm -f .git/LINEARIZE_STOP .git/LINEARIZE_NOTE
  save_state
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

  # anti-spin guard: same commit + same todo length as last iteration
  # means neither --continue nor --skip advanced us. Fail loudly with
  # the real git error instead of looping forever ("the hang").
  t=$(todo_file) || t=/dev/null
  spin_key="$cur:$(wc -l < "$t")"
  if [[ "$spin_key" == "$last_spin" ]]; then
    SPIN=$((SPIN+1))
    if [[ $SPIN -ge 3 ]]; then
      warn "rebase is not advancing (still replaying $cur); git says:"
      GIT_EDITOR=true git rebase --continue 2>&1 | sed 's/^/    /' || true
      if [[ ! -f .git/rebase-merge/message ]] && ! git diff --cached --quiet \
         && [[ -z "$(git ls-files -u)" ]]; then
        # staged changes + no stop record: since git 2.43 a pick whose
        # COMMIT step fails mid-continue is rescheduled without one
        # (sequencer commit_staged_changes — worklog §33)
        warn "diagnosis: a pick's commit step failed mid-continue — usual culprits are"
        warn "commit signing (gpg agent/pinentry) or a failing hook."
        warn "recover: git -C $WT commit   (then rerun with --resume)"
      fi
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
  elif [[ $FINAL_SAFE -eq 1 ]]; then
    still=""
    fs_files=""
    for f in $remaining; do
      stages=$(git ls-files -u -- "$f" | awk '{print $3}' | sort | tr '\n' ',')
      if [[ -z "$(later_touches "$f")" ]]; then
        apply_final "$f"
        fs_files+="$f(final) "
      elif [[ "$stages" == "1,3," || "$stages" == "1,2," || "$stages" == "2,3," ]]; then
        # modify/delete or add/add without base — take archive
        # (which is the correct end state either way).
        apply_final "$f"
        fs_files+="$f(md→final) "
      elif [[ $FINAL_FORCE -eq 1 ]]; then
        apply_final "$f"
        fs_files+="$f(final*) "
      else
        still+="$f "
      fi
    done
    # also stage anything rerere resolved but didn't autoUpdate
    # ($remaining is newline-separated; a space-padded substring test
    # here mismatched multi-file stops and crashed on files deleted
    # in archive — worklog §20)
    for f in $unmerged; do
      grep -qxF "$f" <<<"$remaining" && continue
      [[ -n "$(git ls-files -u -- "$f")" ]] || continue
      if [[ -e "$f" ]]; then git add "$f"; else git rm -q "$f"; fi
    done
    if [[ -z "$still" ]]; then
      handled="final"
      FINAL_HITS=$((FINAL_HITS+1))
      files_disp="${fs_files% }"
    else
      MANUAL=$((MANUAL+1))
      say "stop $STOP: manual — ${still% }"
      say "  replaying: $cur $subj"
      [[ -n "$fs_files" ]] && say "  final-safe already applied to: ${fs_files% }"
      say "  inspect:   scripts/show-stop.sh $REPO"
      say "  then:      scripts/continue-stop.sh $REPO \"<note>\""
      echo "$STOP" > "$WT/.git/LINEARIZE_STOP"
      save_state
      exit 2
    fi
  elif [[ $AUTO -eq 1 ]]; then
    handled="**AUTO/theirs**"
    MANUAL=$((MANUAL+1))
    for f in $unmerged; do
      git checkout --theirs -- "$f" 2>/dev/null || git rm -q "$f" 2>/dev/null || true
      [[ -e "$f" ]] && git add "$f"
    done
  else
    MANUAL=$((MANUAL+1))
    say "stop $STOP: manual — $files_disp"
    say "  replaying: $cur $subj"
    say "  inspect:   scripts/show-stop.sh $REPO"
    say "  then:      (fix files) && git -C $WT add <files>"
    say "  then:      $0 --resume $REPO"
    echo "$STOP" > "$WT/.git/LINEARIZE_STOP"
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

# ── reconcile with archive ──────────────────────────────────────────
# A merge-dropping rebase loses changes that only ever existed in
# merge commits (conflict-resolution tweaks, deletions done while
# merging), and 3-way replay can apply a hunk differently on the new
# base without conflicting. Final modes only correct files that
# CONFLICT, so none of that is caught during the rebase (worklog §28:
# docker resurrected version.txt, aws-lambda-python dropped a
# labeler.yml line, packer resurrected 8 files incl. committed
# conflict markers). Restore the archive tree exactly in one final
# commit; its diff is the audit record of what replay alone lost.
RECONCILE=""
if [[ $AUTO -eq 0 ]] && ! git diff --quiet archive/pre-linearization develop-linear; then
  git checkout -q archive/pre-linearization -- .
  git diff --name-only --diff-filter=A archive/pre-linearization HEAD \
    | while IFS= read -r f; do git rm -q -f -- "$f"; done
  git commit -q -m "Reconcile content with archive/pre-linearization" \
    -m "Restores changes that existed only in merge commits (dropped by the
linearizing rebase) and repairs 3-way replay drift. The tree is now
byte-identical to archive/pre-linearization."
  RECONCILE=$(git diff --shortstat HEAD~1 HEAD | sed 's/^ *//')
  say "reconciliation commit: $RECONCILE"
fi

# ── wrap up ─────────────────────────────────────────────────────────
save_state
{
  echo
  echo "**Totals:** stops=$STOP · rerere=$RERERE_HITS · final-safe=$FINAL_HITS · manual=$MANUAL"
  if [[ -n "$RECONCILE" ]]; then
    echo "**Reconciliation:** $RECONCILE (changes that existed only in merge commits; see the final commit's diff)"
  fi
} >> "$RESLOG"

say "rebase complete: stops=$STOP rerere=$RERERE_HITS final-safe=$FINAL_HITS manual=$MANUAL"
say "develop-linear = $(git rev-parse --short develop-linear)"

# commit new cache entries (local only) — only if the shared cache
# is actually linked (not for auto-resolve / final-force isolated
# runs). Explicit-path staging, same rationale as the train commit
# (worklog §27/§37).
if [[ -L "$WT/.git/rr-cache" ]]; then
  find "$CACHE_DIR" -name .git -prune -o -type f ! -name 'thisimage*' -print0 \
    | xargs -0 git -C "$CACHE_DIR" add --
  if ! git -C "$CACHE_DIR" diff --cached --quiet; then
    git -C "$CACHE_DIR" commit -q -m "Resolutions from $REPO linearization (stops=$STOP)"
    say "committed rr-cache updates ($(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name .git ! -name trained | wc -l) entries total)"
    commit_signed "$CACHE_DIR" HEAD \
      || warn "cache commit is UNSIGNED — cache-push.sh will refuse it (resign.sh --cache-unpushed before pushing; worklog §39)"
  fi
fi

say "logs: $LOG"
say "review: $RESLOG"
say "next:  scripts/verify-linearization.sh $REPO"
