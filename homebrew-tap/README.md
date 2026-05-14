# dalemyers/homebrew-tap

Homebrew tap for tools published by [dalemyers](https://github.com/dalemyers).

## Install a cask from this tap

```sh
brew tap dalemyers/tap
brew install --cask roar
```

Or one-shot without a separate `brew tap`:

```sh
brew install --cask dalemyers/tap/roar
```

## Available casks

| Cask | Description | Source |
|---|---|---|
| `roar` | Post macOS notifications from the shell, with click handlers and `--wait` mode | https://github.com/dalemyers/Roar |

## How releases flow into this tap

The cask files in `Casks/` are kept up to date automatically by the
source projects' release workflows. When `dalemyers/Roar` tags a new
version (e.g. `v1.2.3`), its release workflow:

1. Builds + notarises the `.app`
2. Uploads the artifact to a GitHub Release
3. Opens a pull request to this tap repository with the bumped
   `version` and `sha256` in `Casks/roar.rb`

Maintainer merges the PR; the cask is then live for `brew install`.

Manual edits to the cask formula's URL pattern, dependencies, or
install stanzas should be made in the source project's
`homebrew-tap/Casks/roar.rb` (the source of truth), not directly
here — direct edits drift on the next release.

## Bootstrap (one-time setup)

This repo was bootstrapped by copying `homebrew-tap/Casks/roar.rb`
and `homebrew-tap/README.md` from
[`dalemyers/Roar`](https://github.com/dalemyers/Roar). The tap repo
itself is otherwise empty — Homebrew's
[third-party tap conventions](https://docs.brew.sh/Taps) only
require a `Casks/` directory with `.rb` files.
