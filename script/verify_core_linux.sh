#!/usr/bin/env bash
# Build and test the Swift package's portable parts on Linux, for machines
# with no Mac. Not a substitute for `swift build && swift test` on macOS:
# ShepherdApp's SwiftUI/AppKit views are not compiled here.
#
# The real sources are symlinked into a scratch package that only papers
# over platform differences, never behavior:
#   - a `Darwin` module that re-exports Glibc, and a SQLite3 module map;
#   - `autoreleasepool` and CoreFoundation's boolean type id;
#   - copies of four files with Glibc's types (socket type, timeval,
#     stdout, an explicit `import Darwin`) patched in;
#   - stub UserNotifications and HerdrHostActivator, so AppModel,
#     NotificationManager, and the Foundation-only app files type-check.
#
# Usage: script/verify_core_linux.sh [swift test arguments...]
# Env:   SWIFT_TOOLCHAIN_DIR (default /tmp/swift-toolchain)
#        HERDR_VERIFY_DIR    (default /tmp/herdr-verify)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_DIR="${SWIFT_TOOLCHAIN_DIR:-/tmp/swift-toolchain}"
WORK="${HERDR_VERIFY_DIR:-/tmp/herdr-verify}"
SWIFT_VERSION="6.4.0"
SWIFT_PLATFORM="debian13"
SWIFT_NAME="swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}"
SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM}/swift-${SWIFT_VERSION}-RELEASE/${SWIFT_NAME}.tar.gz"
SQLITE_URL="https://www.sqlite.org/2024/sqlite-amalgamation-3460100.zip"
SHIM="$TOOLCHAIN_DIR/shim"
SWIFT_BIN="$TOOLCHAIN_DIR/$SWIFT_NAME/usr/bin"

[ "$(uname -s)" = "Linux" ] || { echo "Linux only; on macOS run swift build && swift test." >&2; exit 2; }
# The scratch package's Sources/ and Tests/ are deleted on every run.
case "$WORK" in
    ""|/|"$REPO"|"$REPO"/*|"$HOME") echo "HERDR_VERIFY_DIR must be a scratch directory outside the repo" >&2; exit 2 ;;
esac

# --- Toolchain (downloaded once) --------------------------------------------
mkdir -p "$TOOLCHAIN_DIR" "$SHIM"
if [ ! -x "$SWIFT_BIN/swift" ]; then
    echo "Downloading $SWIFT_NAME..."
    curl -sSfL -o "$TOOLCHAIN_DIR/swift.tar.gz" "$SWIFT_URL"
    tar xzf "$TOOLCHAIN_DIR/swift.tar.gz" -C "$TOOLCHAIN_DIR"
    rm "$TOOLCHAIN_DIR/swift.tar.gz"
fi
if [ ! -f "$TOOLCHAIN_DIR/sqlite3.h" ]; then
    curl -sSfL -o "$TOOLCHAIN_DIR/sqlite.zip" "$SQLITE_URL"
    python3 - "$TOOLCHAIN_DIR" <<'PY'
import sys, zipfile
root = sys.argv[1]
with zipfile.ZipFile(f"{root}/sqlite.zip") as z:
    name = next(n for n in z.namelist() if n.endswith("/sqlite3.h"))
    open(f"{root}/sqlite3.h", "wb").write(z.read(name))
PY
    rm "$TOOLCHAIN_DIR/sqlite.zip"
fi
# Debian ships ncursesw, libstdc++, and libsqlite3 without the names the
# toolchain and linker look for.
LIBDIR=/usr/lib/x86_64-linux-gnu
ln -sf "$LIBDIR/libncursesw.so.6" "$TOOLCHAIN_DIR/$SWIFT_NAME/usr/lib/swift/linux/libncurses.so.6"
ln -sf "$LIBDIR/libncursesw.so.6" "$SHIM/libncurses.so.6"
ln -sf "$LIBDIR/libstdc++.so.6" "$SHIM/libstdc++.so"
ln -sf "$LIBDIR/libsqlite3.so.0" "$SHIM/libsqlite3.so"
export PATH="$SWIFT_BIN:$PATH"

# --- Scratch package (rebuilt every run so new files are picked up) --------
rm -rf "$WORK/Sources" "$WORK/Tests" "$WORK/Package.swift"
mkdir -p "$WORK/Sources/Darwin" "$WORK/Sources/SQLite3" "$WORK/Sources/UserNotifications" \
         "$WORK/Sources/HerdrManagerCore" "$WORK/Sources/herdr-manager-mcp" "$WORK/Sources/herdmgr" \
         "$WORK/Sources/ShepherdAppCheck" "$WORK/Tests/HerdrManagerCoreTests"

link_tree() { # $1 source dir, $2 destination dir
    (cd "$1" && find . -name '*.swift') | while read -r f; do
        mkdir -p "$2/$(dirname "$f")"
        ln -sf "$1/$f" "$2/$f"
    done
}

# Copy $1 to $2 through sed script $3, and require $4 in the result.
patched_copy() {
    rm -f "$2"
    sed -e "$3" "$1" > "$2"
    grep -qF -- "$4" "$2" || { echo "Linux patch no longer applies to $1" >&2; exit 1; }
}

link_tree "$REPO/Sources/HerdrManagerCore" "$WORK/Sources/HerdrManagerCore"
link_tree "$REPO/Tests/HerdrManagerCoreTests" "$WORK/Tests/HerdrManagerCoreTests"

patched_copy "$REPO/Sources/HerdrManagerCore/Adapter/NDJSONClient.swift" \
    "$WORK/Sources/HerdrManagerCore/Adapter/NDJSONClient.swift" \
    's/socket(AF_UNIX, SOCK_STREAM, 0)/socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)/; s/tv_usec: Int32(0)/tv_usec: 0/' \
    'tv_usec: 0)'
grep -qF 'Int32(SOCK_STREAM.rawValue)' "$WORK/Sources/HerdrManagerCore/Adapter/NDJSONClient.swift" \
    || { echo "Linux patch no longer applies to NDJSONClient.swift" >&2; exit 1; }
patched_copy "$REPO/Tests/HerdrManagerCoreTests/FakeHerdrServer.swift" \
    "$WORK/Tests/HerdrManagerCoreTests/FakeHerdrServer.swift" \
    's/SOCK_STREAM/Int32(SOCK_STREAM.rawValue)/g' \
    'Int32(SOCK_STREAM.rawValue)'
patched_copy "$REPO/Sources/herdr-manager-mcp/HerdrManagerMCP.swift" \
    "$WORK/Sources/herdr-manager-mcp/HerdrManagerMCP.swift" \
    's/fflush(stdout)/fflush(nil)/' \
    'fflush(nil)'
patched_copy "$REPO/Sources/herdmgr/Herdmgr.swift" \
    "$WORK/Sources/herdmgr/Herdmgr.swift" \
    '1i import Darwin' \
    'import Darwin'

for f in AppModel NotificationManager DwellFormatter UsageFormatter; do
    ln -sf "$REPO/Sources/ShepherdApp/$f.swift" "$WORK/Sources/ShepherdAppCheck/$f.swift"
done

cat > "$WORK/Sources/Darwin/Darwin.swift" <<'EOF'
// Lets `import Darwin` and `Darwin.open(...)` resolve to Glibc.
@_exported import Glibc
EOF

cp "$TOOLCHAIN_DIR/sqlite3.h" "$WORK/Sources/SQLite3/sqlite3.h"
cat > "$WORK/Sources/SQLite3/module.modulemap" <<'EOF'
module SQLite3 [system] {
    header "sqlite3.h"
    link "sqlite3"
    export *
}
EOF

cat > "$WORK/Sources/HerdrManagerCore/_LinuxShims.swift" <<'EOF'
import Foundation

// autoreleasepool is Objective-C only.
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}

// swift-corelibs-foundation does not export CoreFoundation's type ids. It
// boxes JSON true/false as a Bool NSNumber, whose objCType is "c"; JSON
// integers and doubles never are.
typealias CFTypeID = UInt
func CFGetTypeID(_ number: NSNumber) -> CFTypeID {
    String(cString: number.objCType) == "c" ? 1 : 0
}
func CFBooleanGetTypeID() -> CFTypeID { 1 }
EOF

cat > "$WORK/Sources/ShepherdAppCheck/HerdrHostActivatorStub.swift" <<'EOF'
// The real one uses AppKit.
enum HerdrHostActivator {
    static func activate() -> Bool { true }
}
EOF

cat > "$WORK/Sources/UserNotifications/UserNotifications.swift" <<'EOF'
// The slice of UserNotifications Shepherd uses, for type-checking only.
import Foundation

public struct UNAuthorizationOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let alert = UNAuthorizationOptions(rawValue: 1)
    public static let sound = UNAuthorizationOptions(rawValue: 2)
}

public class UNNotificationContent: @unchecked Sendable {}

public final class UNMutableNotificationContent: UNNotificationContent, @unchecked Sendable {
    public var title = ""
    public var body = ""
    public var sound: UNNotificationSound?
    public override init() {}
}

public final class UNNotificationSound: @unchecked Sendable {
    public static let `default` = UNNotificationSound()
}

public class UNNotificationTrigger: @unchecked Sendable {}

public final class UNNotificationRequest: @unchecked Sendable {
    public let identifier: String
    public init(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        self.identifier = identifier
    }
}

public final class UNUserNotificationCenter: @unchecked Sendable {
    public static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    public func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, Error?) -> Void
    ) {}
    public func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)? = nil
    ) {}
}
EOF

cat > "$WORK/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrVerify",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "Darwin", path: "Sources/Darwin"),
        .systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),
        .target(name: "UserNotifications", path: "Sources/UserNotifications"),
        .target(
            name: "HerdrManagerCore",
            dependencies: ["Darwin", "SQLite3"],
            path: "Sources/HerdrManagerCore"
        ),
        .executableTarget(
            name: "herdmgr",
            dependencies: [
                "HerdrManagerCore", "Darwin",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/herdmgr"
        ),
        .executableTarget(
            name: "herdr-manager-mcp",
            dependencies: ["HerdrManagerCore", "Darwin"],
            path: "Sources/herdr-manager-mcp"
        ),
        .target(
            name: "ShepherdAppCheck",
            dependencies: ["HerdrManagerCore", "UserNotifications"],
            path: "Sources/ShepherdAppCheck"
        ),
        .testTarget(
            name: "HerdrManagerCoreTests",
            dependencies: ["HerdrManagerCore", "Darwin", "SQLite3"],
            path: "Tests/HerdrManagerCoreTests"
        ),
    ]
)
EOF

# --- Build and test -----------------------------------------------------------
cd "$WORK"
for target in HerdrManagerCore herdr-manager-mcp herdmgr ShepherdAppCheck; do
    echo "== swift build --target $target"
    swift build --target "$target" -Xlinker -L"$SHIM"
done
echo "== swift test $*"
swift test -Xlinker -L"$SHIM" "$@"
