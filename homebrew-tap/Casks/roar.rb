# Homebrew cask for `roar`.
#
# This file is the source of truth for the cask. The release
# workflow at `.github/workflows/release.yml` syncs it to
# `dalemyers/homebrew-tap`'s `Casks/roar.rb` on every tagged
# release, rewriting `version` and `sha256` against the just-built
# artifact. Manual edits to the URL pattern, dependencies, or
# install stanzas land here and propagate on the next release.
#
# Install (once the tap is published):
#
#   brew tap dalemyers/tap
#   brew install --cask roar
#
# Or one-shot:
#
#   brew install --cask dalemyers/tap/roar

cask "roar" do
  # `version` and `sha256` are rewritten by the release workflow.
  # The placeholders here are what the bootstrap commit ships
  # before the first release runs; they are intentionally values
  # that would fail a real install so a half-set-up tap surfaces
  # the misconfiguration loudly instead of silently downloading
  # something the user didn't expect.
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # Release artifacts are hosted on the Roar repo's GitHub
  # Releases. The `app.zip` form is ditto-packaged so Apple's
  # extended attributes (signing metadata, notarisation receipt)
  # survive the round-trip — the bare `tar.gz` strips those and
  # would fail Gatekeeper on first launch.
  url "https://github.com/dalemyers/Roar/releases/download/v#{version}/roar-#{version}.app.zip"
  name "Roar"
  desc "Post macOS notifications from the shell, with click handlers and --wait"
  homepage "https://github.com/dalemyers/Roar"

  # `livecheck` lets `brew livecheck roar` and `brew bump-cask-pr`
  # detect new releases automatically. `:github_latest` reads the
  # repo's latest release tag (`v1.2.3`) and feeds it back into
  # `version` so the cask's URL pattern resolves.
  livecheck do
    url :url
    strategy :github_latest
  end

  # Roar's deployment target is macOS 13.0 (Ventura). The bundle's
  # `LSMinimumSystemVersion` already enforces this at launch; the
  # cask declaration surfaces the requirement at install time so
  # users on older systems get a clear error rather than a silent
  # post-install failure when the .app refuses to start.
  depends_on macos: ">= :ventura"

  # Install the .app to /Applications. Cask handles the move
  # idempotently — re-installs replace the existing copy.
  app "Roar.app"

  # Symlink the embedded CLI binary onto Homebrew's bin path so
  # `roar` works from any shell without the user having to add
  # `/Applications/Roar.app/Contents/MacOS` to PATH.
  #
  # `#{appdir}` resolves to /Applications (or wherever the user's
  # appdir is configured — Homebrew supports a per-user override
  # for sandbox/no-sudo installs). The binary stanza creates a
  # symlink, not a wrapper script, so future updates of the .app
  # are picked up without re-running the cask.
  binary "#{appdir}/Roar.app/Contents/MacOS/roar"

  # Install the man page from inside the .app bundle into
  # Homebrew's manpath. The .app build phase
  # (`project.yml`'s copyFiles directive) lands `man/roar.1`
  # at `Roar.app/Contents/Resources/man/man1/roar.1`. The cask's
  # `manpage` stanza copies that file into
  # `HOMEBREW_PREFIX/share/man/man1/roar.1`, which is on every
  # Homebrew user's MANPATH by default — `man roar` works
  # immediately after install with no manual MANPATH edit.
  manpage "Roar.app/Contents/Resources/man/man1/roar.1"

  # Clean up user-state on `brew uninstall --zap`. The bundle id
  # `io.myers.roar` matches `project.yml`'s
  # `CFBundleIdentifier` — keep these in sync if the bundle id
  # ever changes. macOS writes these locations even for an
  # LSUIElement bundle with no GUI windows: `Preferences/`
  # holds anything `NSUserDefaults` writes (currently nothing,
  # but a future feature might), and the saved-state directory
  # is created by AppKit on first launch.
  #
  # `trash:` (vs. `delete:`) sends the files to the user's
  # Trash so an over-eager `--zap` is reversible.
  zap trash: [
    "~/Library/Preferences/io.myers.roar.plist",
    "~/Library/Saved Application State/io.myers.roar.savedState",
  ]
end
