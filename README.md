# Lineage sync playground kit (SANDBOX)

Hands-on rehearsal of the rebase-based lineage sync + merge-to-publish
flow, against live sandbox repos in the `dhs-ncats` org. Nothing here can
touch cisagov: the driver refuses it outright.

**Start here: [`docs/playground.md`](docs/playground.md)** — five
day-in-the-life scenarios (~5–10 min each). Design and context:
[`docs/design.md`](docs/design.md),
[`docs/team-decisions.md`](docs/team-decisions.md).

## Prerequisites

- `git` (≥ 2.43) and `gh` logged in (`gh auth status`) with write
  access to the `dhs-ncats` org repos, and the `workflow` scope
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
git clone https://github.com/dhs-ncats/lineage-playground.git
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
