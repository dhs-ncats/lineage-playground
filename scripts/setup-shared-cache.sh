#!/usr/bin/env bash
# Initialise ./rr-cache/ as the shared rerere cache repo.
# Safe to re-run.
source "$(dirname "$0")/common.sh"

CACHE_REMOTE=${CACHE_REMOTE:-"$ORG_URL/rerere-cache.git"}

# callers may point CACHE_DIR anywhere (playground, gh extension) —
# creating it is this script's job
mkdir -p "$CACHE_DIR"

if [[ -d "$CACHE_DIR/.git" ]]; then
  say "shared cache already initialised at $CACHE_DIR"
  ensure_identity "$CACHE_DIR"
  # wire up the canonical remote if this cache predates it
  git -C "$CACHE_DIR" remote get-url origin >/dev/null 2>&1 \
    || { git -C "$CACHE_DIR" remote add origin "$CACHE_REMOTE"; say "origin → $CACHE_REMOTE"; }
elif [[ -z "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]] \
     && git clone -q "$CACHE_REMOTE" "$CACHE_DIR" 2>/dev/null; then
  # fresh start: the shared history on GitHub IS the cache — never
  # seed an unrelated local root when the canonical one is reachable
  # (that is how divergent cache histories happen; worklog §34)
  say "cloned shared cache from $CACHE_REMOTE"
  ensure_identity "$CACHE_DIR"
else
  warn "could not clone $CACHE_REMOTE — initialising a fresh local cache"
  say "initialising shared rr-cache repo at $CACHE_DIR"
  git -C "$CACHE_DIR" init -q
  ensure_identity "$CACHE_DIR"
  git -C "$CACHE_DIR" remote add origin "$CACHE_REMOTE" 2>/dev/null || true
  git -C "$CACHE_DIR" add -A
  git -C "$CACHE_DIR" commit -q -m "Initial rr-cache" --allow-empty
fi
# same script-speed state pins as prep_repo (worklog §27/§32)
git -C "$CACHE_DIR" config core.fsmonitor false
git -C "$CACHE_DIR" config core.untrackedCache false

# rerere's REUSE path drops `thisimage` scratch files into entry dirs;
# they are never resolution data and must not churn the cache repo
# (worklog §30). Ignore them, and untrack any committed by older runs.
if [[ ! -f "$CACHE_DIR/.gitignore" ]] || ! grep -qx 'thisimage\*' "$CACHE_DIR/.gitignore"; then
  printf 'thisimage*\n' >> "$CACHE_DIR/.gitignore"
fi
if [[ -n "$(git -C "$CACHE_DIR" ls-files -- '*/thisimage*')" ]]; then
  git -C "$CACHE_DIR" rm -q --cached -- '*/thisimage*'
fi
git -C "$CACHE_DIR" add -- .gitignore
if ! git -C "$CACHE_DIR" diff --cached --quiet; then
  git -C "$CACHE_DIR" commit -q -m "Ignore rerere thisimage scratch files"
fi

say "entries: $(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name .git ! -name trained | wc -l)"
