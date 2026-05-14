# Installing Roar

Roar is a macOS-only tool that builds from source today. There is no
Homebrew formula yet, and the binary is distributed as a signed +
notarised `.app` from GitHub Releases for tagged versions.

## Requirements

| Requirement                 | Version             |
|-----------------------------|---------------------|
| macOS                       | 13.0 or later       |
| Xcode (Command Line Tools)  | 15 or later         |
| Swift                       | 5.10 (bundled with Xcode) |
| [`xcodegen`](https://github.com/yonaskolb/XcodeGen) | 2.40+        |
| Optional: `mandoc`          | for `man` page rendering on macOS |

`xcodegen` regenerates `Roar.xcodeproj` from `project.yml`. The
`.xcodeproj` is checked in for IDE convenience but `project.yml` is
the source of truth.

```sh
brew install xcodegen
```

## Build from source

Clone, regenerate the project, and run the test suite to verify your
toolchain:

```sh
git clone https://github.com/dalemyers/Roar.git
cd Roar
xcodegen generate
xcodebuild -project Roar.xcodeproj -scheme roar -configuration Release build
xcodebuild -project Roar.xcodeproj -scheme roar -destination 'platform=macOS' test
```

The build output lives in DerivedData; to find the built `.app`:

```sh
xcodebuild -project Roar.xcodeproj -scheme roar -configuration Release \
    -showBuildSettings 2>/dev/null \
    | awk -F= '/^[[:space:]]*BUILT_PRODUCTS_DIR/{gsub(/^ +/,"",$2);print $2}'
```

## Install the `.app`

Copy the built bundle into `/Applications` so LaunchServices treats
Roar as a normal app (this is what lets notifications come from
"Roar" with a proper icon in Notification Center):

```sh
APP=$(xcodebuild -project Roar.xcodeproj -scheme roar -configuration Release \
    -showBuildSettings 2>/dev/null \
    | awk -F= '/^[[:space:]]*BUILT_PRODUCTS_DIR/{gsub(/^ +/,"",$2);print $2}')
cp -R "$APP/roar.app" /Applications/
```

Roar uses `LSUIElement: true` so it does **not** appear in the Dock
or the application switcher; it's a CLI tool that happens to be
packaged as an app bundle because `UNUserNotificationCenter` requires
one.

## Install the CLI

The binary inside the bundle is the actual CLI entry point. Symlink
it onto your `PATH`:

```sh
ln -sf /Applications/roar.app/Contents/MacOS/roar /usr/local/bin/roar
# or under ~/.local/bin if you'd rather not need sudo
mkdir -p ~/.local/bin
ln -sf /Applications/roar.app/Contents/MacOS/roar ~/.local/bin/roar
```

Verify:

```sh
roar --version
roar --help
```

## Install the man page

```sh
./man/install.sh           # per-user, into ~/.local/share/man
./man/install.sh --system  # /usr/local/share/man (needs sudo)
```

If `man roar` doesn't resolve afterwards, you may need to add the
per-user man directory to `MANPATH`:

```sh
echo 'export MANPATH="$HOME/.local/share/man:${MANPATH:-}"' >> ~/.zshrc
```

## Granting notification permission

On the first `roar send` invocation, Roar requests **provisional**
notification authorization. macOS grants this silently — no permission
dialog, no blocking prompt — so cron / launchd / CI jobs can post
without anyone tapping anything. The trade-off: provisional
notifications post quietly to Notification Center (no banner, no
sound, no badge break-through) until the user promotes the app.

To promote:

- Tap **Keep** on the first notification Roar delivers, **or**
- Open **System Settings → Notifications → Roar** and enable the
  alert style you want.

Once promoted, all subsequent notifications post with full
affordances. The provisional state survives across reboots.

If notification permission has been denied at some point and you want
to re-enable it:

1. System Settings → Notifications → scroll to **Roar**.
2. Toggle **Allow Notifications** on.
3. Choose Banner or Alert.

## Signed releases (for non-buildable consumers)

Tagged commits (`v*`) trigger a GitHub Actions release workflow that:

1. Builds Roar with the project's Developer ID Application
   certificate.
2. Notarises the bundle via `xcrun notarytool`.
3. Staples the notarisation ticket onto `roar.app`.
4. Publishes a `.tar.gz`, `.app.zip`, and a `sha256` manifest to a
   new GitHub Release.

Download from the [Releases page](https://github.com/dalemyers/Roar/releases),
verify the checksum, and install:

```sh
shasum -a 256 roar-v3.0.0.app.zip
# compare against roar-v3.0.0.sha256
unzip roar-v3.0.0.app.zip -d /Applications/
ln -sf /Applications/roar.app/Contents/MacOS/roar /usr/local/bin/roar
```

## Uninstall

```sh
rm -f /usr/local/bin/roar ~/.local/bin/roar
rm -rf /Applications/roar.app
rm -f ~/.local/share/man/man1/roar.1 /usr/local/share/man/man1/roar.1

# Optional: drop the bundle's notification permissions and history
# (this clears delivered + pending notifications and the notification
# permission record so a fresh install gets the first-run experience).
defaults delete io.myers.roar 2>/dev/null
osascript -e 'tell application "NotificationCenter" to quit' 2>/dev/null
killall usernoted 2>/dev/null    # respawned by launchd
```

## Verifying installation

```sh
which roar                       # /usr/local/bin/roar
ls -l "$(which roar)"            # symlink → /Applications/roar.app/...
roar --version                   # prints the version baked into the binary
roar settings                    # prints the OS-side notification settings
roar send --body "It works"      # should produce a banner / NC entry
```

If `roar send` produces no banner and no Notification Center entry,
see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
