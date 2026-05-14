# Building Roar from source

This document is for **contributors and people who want to hack on
Roar**. If you just want to use the tool, install via Homebrew —
see the [README](https://github.com/dalemyers/Roar#install) for
`brew install --cask dalemyers/tap/roar` and friends.

## Requirements

| Requirement                 | Version             |
|-----------------------------|---------------------|
| macOS                       | 13.0 or later       |
| Xcode (or Command Line Tools) | 15 or later       |
| Swift                       | 5.10 (bundled with Xcode) |
| [`xcodegen`](https://github.com/yonaskolb/XcodeGen) | 2.40+ |
| Optional: `rsvg-convert`    | only needed if you edit `Resources/icon.svg` and want to regenerate `Resources/Roar.icns` |
| Optional: `swiftlint`       | matches the CI lint gate; install via `brew install swiftlint` |

`xcodegen` regenerates `Roar.xcodeproj` from `project.yml`.
`project.yml` is the source of truth — the `.xcodeproj` is generated
each time and **not** checked into git.

```sh
brew install xcodegen
```

## Build

```sh
git clone https://github.com/dalemyers/Roar.git
cd Roar
xcodegen generate
xcodebuild -project Roar.xcodeproj -scheme roar -configuration Release build
```

Find the resulting `.app`:

```sh
APP=$(xcodebuild -project Roar.xcodeproj -scheme roar -configuration Release \
    -showBuildSettings 2>/dev/null \
    | awk -F= '/^[[:space:]]*BUILT_PRODUCTS_DIR/{gsub(/^ +/,"",$2);print $2}')
echo "Built bundle: $APP/Roar.app"
```

Roar uses `LSUIElement: true` so the built bundle does **not** appear
in the Dock or application switcher; it's a CLI that happens to be
packaged as an `.app` because `UNUserNotificationCenter` requires a
bundle.

## Run the test suite

```sh
xcodebuild -project Roar.xcodeproj -scheme roar -destination 'platform=macOS' test
```

CI (`.github/workflows/ci.yml`) runs this on every push to `main` and
every PR. The project's build settings enable
`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, so any new warning fails the
build.

## Lint

```sh
swiftlint --strict
```

`.swiftlint.yml` encodes the project's tuned rule set. CI uses
`--strict` so any new lint warning fails the workflow. Local edits
should produce a clean `swiftlint --strict` before pushing.

## Install your local build

If you want to test your build by `roar`-ing from the shell, replace
the installed bundle with the freshly-built one:

```sh
# Use the $APP from the BUILT_PRODUCTS_DIR recipe above.
sudo rm -rf /Applications/Roar.app
ditto "$APP/Roar.app" /Applications/Roar.app

# Re-register so LaunchServices picks up the new build and
# `usernoted` refreshes its icon cache.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f /Applications/Roar.app
killall usernoted 2>/dev/null || true
```

The Homebrew-managed symlinks in `/opt/homebrew/bin/roar` and
`/opt/homebrew/share/man/man1/roar.1` still point inside the
bundle, so they automatically resolve to your local build after
the `ditto`.

## Regenerate the app icon

`Resources/Roar.icns` is a generated artifact. The source is
`Resources/icon.svg`. After editing the SVG, regenerate:

```sh
brew install librsvg                 # one-time, for `rsvg-convert`
./scripts/generate-icon.sh
```

Commit both `Resources/icon.svg` and the regenerated
`Resources/Roar.icns` together — the build phase that bundles the
icon reads the `.icns`, not the `.svg`.

## Producing a signed, notarised build

Local builds default to ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`),
which works for testing but won't pass Gatekeeper on someone else's
machine. The Developer ID + notarisation pipeline runs from CI on
every `v*` tag push — see the
[`CI / release` section of the README](https://github.com/dalemyers/Roar#ci--release) for
the secret provisioning and tag workflow.
