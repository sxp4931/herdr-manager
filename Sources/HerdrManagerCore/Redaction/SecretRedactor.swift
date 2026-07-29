import Foundation

// MARK: - SecretRedactor

public final class SecretRedactor: Sendable {

    public struct RedactionResult: Sendable {
        public let redactedText: String
        public let redactionCount: Int

        public init(redactedText: String, redactionCount: Int) {
            self.redactedText = redactedText
            self.redactionCount = redactionCount
        }
    }

    // Patterns to detect and redact
    private static let patterns: [(regex: NSRegularExpression, replacement: String)] = {
        let defs: [(pattern: String, replacement: String)] = [
            // OpenAI / generic sk- keys
            ("sk-[A-Za-z0-9]{20,}", "sk-[REDACTED]"),
            // GitHub personal access tokens
            ("ghp_[A-Za-z0-9]{36}", "ghp_[REDACTED]"),
            // AWS access key IDs
            ("AKIA[0-9A-Z]{16}", "AKIA[REDACTED]"),
            // Bearer tokens in headers
            ("Bearer\\s+[A-Za-z0-9\\-._~+/]+=*", "Bearer [REDACTED]"),
            // PEM private keys
            ("-----BEGIN[A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END[A-Z ]*PRIVATE KEY-----", "[REDACTED PRIVATE KEY]"),
            // Generic API keys (key= or api_key= followed by value)
            ("(?i)(api[_-]?key|secret|token|password)\\s*[=:]\\s*['\"]?[^\\s'\"&]{8,}", "$1=[REDACTED]"),
        ]

        var result: [(NSRegularExpression, String)] = []
        for (pattern, replacement) in defs {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result.append((regex, replacement))
            }
        }
        return result
    }()

    public init() {}

    public func redact(_ text: String) -> RedactionResult {
        var mutable = text
        var count = 0

        for (regex, replacement) in Self.patterns {
            let range = NSRange(mutable.startIndex..., in: mutable)
            let matches = regex.numberOfMatches(in: mutable, options: [], range: range)
            if matches > 0 {
                mutable = regex.stringByReplacingMatches(in: mutable, options: [], range: range, withTemplate: replacement)
                count += matches
            }
        }

        return RedactionResult(redactedText: mutable, redactionCount: count)
    }
}
