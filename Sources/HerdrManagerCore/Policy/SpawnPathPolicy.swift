import Foundation

// MARK: - SpawnPathPolicy

/// Pure, unit-testable predicates for the MCP `session.spawn` safety gates.
///
/// These were originally inlined in `Sources/herdr-manager-mcp/main.swift` and
/// could not be exercised without a live MCP server. Extracted here so the
/// path-component allowlist, select-index bounds, and supported-kind checks
/// can be covered by regression tests.
public enum SpawnPathPolicy: Sendable {

    /// Supported agent kinds for `session.spawn`.
    public static let supportedKinds: Set<String> = [
        "aider", "claude", "codex", "gemini", "opencode"
    ]

    /// True iff `index` is a valid menu-select index (0...20 inclusive).
    public static func isValidSelectIndex(_ index: Int) -> Bool {
        return (0...20).contains(index)
    }

    /// True iff `kind` (case-insensitive) is a supported agent kind.
    public static func isSupportedSpawnKind(_ kind: String) -> Bool {
        return supportedKinds.contains(kind.lowercased())
    }

    /// Convert a human-facing MCP session name into the name grammar Herdr
    /// accepts for an agent: lowercase, starts with a letter, and contains
    /// only ASCII letters, digits, hyphens, or underscores (max 32 chars).
    public static func canonicalAgentName(_ name: String, fallback: String) -> String {
        var result = ""
        var previousWasSeparator = false

        for scalar in name.lowercased().unicodeScalars {
            let isLetter = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            let isUnderscore = scalar.value == 95

            if isLetter || isDigit || isUnderscore {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !result.isEmpty && !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        while result.last == "-" {
            result.removeLast()
        }

        if result.isEmpty {
            result = fallback.lowercased()
        }

        if let first = result.unicodeScalars.first,
           !(first.value >= 97 && first.value <= 122) {
            result = "agent-" + result
        }

        result = String(result.prefix(32))
        while result.last == "-" {
            result.removeLast()
        }

        return result.isEmpty ? "agent" : result
    }

    /// True iff `path` resolves (with symlinks expanded) to a location that
    /// sits within one of the `allowedRoots`.
    ///
    /// Comparison is done on path **components**, not string prefixes, so a
    /// sibling like `/repo-evil` does NOT match an allowed root of `/repo`.
    /// The path must exist on disk (so symlink resolution is meaningful);
    /// nonexistent paths are rejected.
    public static func isPathWithinAllowedRoots(
        _ path: String,
        allowedRoots: [String]
    ) -> Bool {
        // Expand tilde and standardize, then resolve symlinks.
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        let resolvedURL = URL(fileURLWithPath: standardized).resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path

        // The path must exist and be a directory.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }

        let resolvedComponents = resolvedURL.pathComponents
        for allowedRoot in allowedRoots {
            let allowedComponents = URL(fileURLWithPath: allowedRoot).pathComponents
            guard resolvedComponents.count >= allowedComponents.count else { continue }
            var match = true
            for i in 0..<allowedComponents.count {
                if resolvedComponents[i] != allowedComponents[i] {
                    match = false
                    break
                }
            }
            if match { return true }
        }
        return false
    }
}
