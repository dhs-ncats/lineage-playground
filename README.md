# Lineage sync playground kit (SANDBOX)

Hands-on rehearsal of the rebase-based lineage sync + merge-to-publish
flow, against a live two-tier sandbox lineage in the `dhs-ncats` org
(sandbox-skeleton-generic → sandbox-skeleton-ansible-role →
sandbox-ansible-role-banner, seeded from the real cisagov histories).
Nothing here can touch cisagov: the driver refuses it outright and
verifies every repo name resolves inside the sandbox (the org's bare
historical names carry rename redirects into cisagov — never create
or push to one).

**Start here: [`docs/playground.md`](docs/playground.md)** — the
day-in-the-life scenarios (~5–10 min each). Design and context:
[`docs/design.md`](docs/design.md),
[`docs/team-decisions.md`](docs/team-decisions.md).

## Prerequisites

- `git` (≥ 2.43) and `gh` logged in (`gh auth status`) with write
  access to the `dhs-ncats` org repos, and the `workflow` scope
  (`gh auth refresh -s workflow` if pushes of workflow files are
  refused).
- Commit signing that works WITHOUT prompting — the sync re-signs
  every replayed commit. No signing set up? A passwordless SSH
  signing key is fine for the sandbox:

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

## The gh extension (maximum fidelity)

The real tool-to-be lives at `dhs-ncats/gh-skeleton`: the actual
cisagov/gh-skeleton history with the lineage subcommands committed on
top (`sync`, `linearize`, `verify`, `verify-sync`, `publish`,
`cache`, `stop`, `smoke`).

> **⚠ Default org: the extension assumes `cisagov`.** That is
> deliberate — it is the production tool, and its defaults (clone
> URLs, the shared rr-cache remote) point at the real org. Run it
> bare in the sandbox and it will read real cisagov repos (pushes
> stay gated: interactive-only, and `--yes` is refused for cisagov).
> For sandbox play, ALWAYS source the env file first — it points
> ORG_URL at `dhs-ncats` and keeps work trees and the rr-cache inside
> this clone's `work/playground/`, isolated from the real cache.

```bash
# gh allows ONE extension per name — swap out the cisagov one first:
gh extension remove skeleton 2>/dev/null
gh extension install dhs-ncats/gh-skeleton

source ./sandbox-env              # REQUIRED for sandbox use (see above)
gh skeleton smoke                 # sandboxed self-test
gh skeleton sync --parent sandbox-skeleton-ansible-role sandbox-ansible-role-banner
gh skeleton sync --push --yes --parent sandbox-skeleton-ansible-role sandbox-ansible-role-banner

# when done, restore the real one:
gh extension remove skeleton && gh extension install cisagov/gh-skeleton
```

Whether the default org should instead become a flag (matching
`clone`'s `--src-org`/`--dest-org`) is an open question for the
upstream PR — undecided for now.

## House rules

- **One driver at a time** — the sandbox repos are shared state.
  `playground.sh reset` before a session; shout in the team channel.
- The local source of truth for these scripts/docs is the rerere
  harness tree; update the kit with `playground.sh kit` from there,
  don't edit this repo directly.
