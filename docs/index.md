# Roar

A CLI for posting macOS notifications from the shell, with optional
click handlers (open a URL, run a shell command, activate an app),
scheduled delivery, custom action buttons, and a `--wait` mode that
blocks until the user clicks, picks a button, or dismisses the
notification.

```sh
roar send --title "Build complete" --body "$(git log -1 --pretty=%B)"
```

Roar is an ad-hoc-signed AppKit bundle with no UI surface — it
sets `LSUIElement: true`, so notifications post quietly and the
binary behaves like a normal terminal CLI: it exits as soon as
`usernoted` has accepted the request, or when the user
interacts (in `--wait` mode).

## Install

Requires macOS 13 (Ventura) or later.

### Homebrew (recommended)

```sh
brew install --cask dalemyers/tap/roar
```

That installs `Roar.app` to `/Applications`, symlinks the `roar`
binary onto your Homebrew bin path, and installs the man page so
`man roar` works without further setup. Upgrade with
`brew upgrade --cask dalemyers/tap/roar`; uninstall with state
cleanup via `brew uninstall --cask --zap dalemyers/tap/roar`.

### Manual (no Homebrew)

Download `roar-<version>.app.zip` from the
[Releases](https://github.com/dalemyers/Roar/releases) page,
unzip into `/Applications`, then symlink the inner binary and
man page onto your `PATH` / `MANPATH`:

```sh
unzip "roar-<version>.app.zip"
mv Roar.app /Applications/
# Apple Silicon (Homebrew prefix /opt/homebrew):
ln -sf /Applications/Roar.app/Contents/MacOS/roar \
       /opt/homebrew/bin/roar
ln -sf /Applications/Roar.app/Contents/Resources/man/man1/roar.1 \
       /opt/homebrew/share/man/man1/roar.1
# Intel (Homebrew prefix /usr/local): replace /opt/homebrew with
# /usr/local in the two paths above.
```

Releases are notarised and stapled, so they pass Gatekeeper
offline without further dance.

## Where to read next

- **[Concepts](CONCEPTS.md)** — how macOS notifications work
  and why Roar is shaped the way it is.
- **[Reference](reference/index.md)** — every flag, every
  subcommand. The Ctrl-F page.
- **[Cookbook](COOKBOOK.md)** — task-oriented recipes.
- **[Scripting](SCRIPTING.md)** — the `--wait` stdout protocol,
  exit codes, and patterns for shell / Python / CI.
- **[FAQ](FAQ.md)** — recurring design / scope questions.
- **[Security](SECURITY.md)** — full threat model and per-gate
  rationale.
- **[Troubleshooting](TROUBLESHOOTING.md)** — symptom → fix.
- **[Build from source](BUILD.md)** + **[Release](RELEASE.md)** —
  contributor-tier docs.

## Safety pointer

Before using `--exec` or `--allow-url-scheme`, read
[Security](SECURITY.md) — particularly the same-bundle-id
spoofing discussion. Roar's click handler trusts the
notification's userInfo, and macOS doesn't scope notification
delivery by sending process, so any same-user process posting
under `io.myers.roar` can drive the click handler. This is
inherent to the ad-hoc-signed local-CLI threat model and the
defences Roar does apply are catalogued there.
