import XCTest
@testable import roar

/// Pin the envp construction used for `/bin/sh -c` shell-on-click
/// commands. The previous implementation passed the parent's
/// environment through verbatim, letting a hostile parent shell set
/// PATH, BASH_ENV, IFS, LD_*, etc. to influence command resolution
/// in `--exec`. The current implementation explicitly pins PATH
/// and inherits only a small allow-list of "benign" variables.
final class SpawnEnvironmentTests: XCTestCase {

    /// Parse the `KEY=VALUE` strings the builder returns into a
    /// dictionary so individual entries can be asserted.
    private func env(from strings: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for s in strings {
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq])
            let value = String(s[s.index(after: eq)...])
            out[key] = value
        }
        return out
    }

    func testPATHIsPinnedRegardlessOfParent() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "PATH": "/Users/victim/.attacker-bin:/usr/bin",
            "HOME": "/Users/victim",
        ]))
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin",
                       "PATH must be pinned to the system default")
    }

    func testHostilePATHIsDropped() throws {
        // The headline attack: parent sets PATH=~/.attacker-bin first.
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "PATH": "/Users/victim/.attacker-bin:/usr/bin",
        ]))
        let path = try XCTUnwrap(env["PATH"])
        XCTAssertFalse(path.contains(".attacker-bin"))
    }

    func testBASHENVIsDropped() {
        // `/bin/sh` reads BASH_ENV / ENV at startup and sources what
        // they name — must NOT propagate into the spawned shell.
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "BASH_ENV": "/tmp/attacker.sh",
            "ENV": "/tmp/attacker.sh",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["BASH_ENV"])
        XCTAssertNil(env["ENV"])
    }

    func testIFSIsDropped() {
        // `IFS` change defeats simple defences around `--exec`
        // tokenisation — drop it.
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "IFS": ":",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["IFS"])
    }

    func testCDPATHIsDropped() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "CDPATH": "/tmp/evil",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["CDPATH"])
    }

    func testLDLibraryPathsAreDropped() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "LD_LIBRARY_PATH": "/tmp/evil",
            "LD_PRELOAD": "/tmp/evil.so",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "DYLD_LIBRARY_PATH": "/tmp/evil",
            "DYLD_FRAMEWORK_PATH": "/tmp/evil",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["LD_LIBRARY_PATH"])
        XCTAssertNil(env["LD_PRELOAD"])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["DYLD_LIBRARY_PATH"])
        XCTAssertNil(env["DYLD_FRAMEWORK_PATH"])
    }

    func testShelloptsIsDropped() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "SHELLOPTS": "errexit",
            "BASHOPTS": "extdebug",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["SHELLOPTS"])
        XCTAssertNil(env["BASHOPTS"])
    }

    func testHOMEIsPropagated() {
        // HOME is required by `cd "${HOME:-/}"` in the shell prefix
        // and by many commands users would invoke. It's in the
        // allow-list because it doesn't influence command resolution
        // (PATH and friends do).
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "HOME": "/Users/example",
        ]))
        XCTAssertEqual(env["HOME"], "/Users/example")
    }

    func testLocalisationKeysArePropagated() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "C",
            "LC_CTYPE": "UTF-8",
            "TZ": "Europe/London",
        ]))
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["LC_ALL"], "C")
        XCTAssertEqual(env["LC_CTYPE"], "UTF-8")
        XCTAssertEqual(env["TZ"], "Europe/London")
    }

    func testTMPDIRIsPropagated() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "TMPDIR": "/var/folders/xx/T/",
        ]))
        XCTAssertEqual(env["TMPDIR"], "/var/folders/xx/T/")
    }

    /// A non-allow-listed key the user might *want* propagated.
    /// Document the policy: it's dropped. Users can re-export it
    /// inside their `--exec` value.
    func testRandomKeyIsDropped() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "EDITOR": "vim",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["EDITOR"])
    }

    /// Empty parent env still produces a working environment for the
    /// shell — PATH is the safe default, even if HOME etc. are absent.
    func testEmptyParentEnvProducesPinnedPath() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [:]))
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(env["HOME"])
    }

    /// A hostile parent that sets `HOME=/tmp=/x` would otherwise
    /// produce a malformed envp entry — `posix_spawn` lays out
    /// `KEY=VALUE\0` runs and the child's `env`/`getenv` parser
    /// splits on the FIRST `=`. Drop any inherited value that
    /// contains `=` outright so the malformed entry never reaches
    /// `posix_spawn`. The user can always re-export the variable
    /// inside their `--exec` value if they really need an `=`.
    func testHomeWithEqualsIsDropped() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "HOME": "/tmp=/x",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["HOME"],
                     "HOME containing `=` must be dropped to avoid malformed envp entry")
    }

    /// NUL in an inherited value would truncate at the C-string
    /// bridge and produce a malformed envp entry with attacker-
    /// controlled tail content. Drop outright.
    func testHomeWithNULIsDropped() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "HOME": "/Users/example\0/attacker",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["HOME"],
                     "HOME containing NUL must be dropped to avoid envp truncation")
    }

    /// TMPDIR, TZ — any inherited value — gets the same screening.
    /// Pin so a regression dropping only HOME would still fail.
    func testTMPDIRWithEqualsIsDropped() {
        let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
            "TMPDIR": "/tmp=/x",
            "PATH": "/usr/bin",
        ]))
        XCTAssertNil(env["TMPDIR"])
    }

    /// The full inherited allow-list per `ShellExecutor.buildSpawnEnvironment`.
    /// Kept in sync with the production source manually — if the
    /// allow-list grows there, add the key here and the parametrised
    /// tests below cover it automatically.
    ///
    /// `PATH` is intentionally NOT in this list: PATH is *pinned* by the
    /// builder (never inherited), so the propagation / drop test
    /// shape doesn't apply.
    private static let inheritedEnvKeys = [
        "HOME", "USER", "LOGNAME",
        "LANG", "LANGUAGE",
        "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES",
        "LC_MONETARY", "LC_NUMERIC", "LC_TIME",
        "TZ", "TMPDIR",
    ]

    /// For every key in the inherited allow-list: a clean value
    /// propagates through to the spawned env. Catches regressions
    /// where a key is silently dropped from the allow-list (e.g. a
    /// refactor that splits the list and forgets to merge a slice).
    func testEveryInheritedKeyPropagatesCleanValue() {
        for key in Self.inheritedEnvKeys {
            // A distinguishable value per key so a mis-routing bug
            // (e.g. always returning the same key's value) is visible.
            let value = "clean-\(key)-value"
            let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
                key: value,
                "PATH": "/usr/bin",
            ]))
            XCTAssertEqual(
                env[key], value,
                "key \(key) should propagate its clean value verbatim"
            )
        }
    }

    /// For every inherited key: a value containing `=` is dropped.
    /// `posix_spawn` envp entries are NUL-terminated KEY=VALUE runs,
    /// and the child's `getenv` parser splits on the FIRST `=` — a
    /// value with an embedded `=` would corrupt the entry boundary.
    func testEveryInheritedKeyDropsValueWithEquals() {
        for key in Self.inheritedEnvKeys {
            let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
                key: "before=after",
                "PATH": "/usr/bin",
            ]))
            XCTAssertNil(
                env[key],
                "key \(key) with `=` in value must be dropped"
            )
        }
    }

    /// For every inherited key: a value containing NUL is dropped.
    /// NUL truncates at the C-string bridge `posix_spawn` uses,
    /// producing a malformed envp entry with attacker-controlled tail.
    func testEveryInheritedKeyDropsValueWithNUL() {
        for key in Self.inheritedEnvKeys {
            let env = env(from: ShellExecutor.buildSpawnEnvironment(parentEnv: [
                key: "before\0after",
                "PATH": "/usr/bin",
            ]))
            XCTAssertNil(
                env[key],
                "key \(key) with NUL in value must be dropped"
            )
        }
    }
}
