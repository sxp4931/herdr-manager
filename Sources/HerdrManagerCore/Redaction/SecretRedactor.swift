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
            // Anthropic keys (hyphens; generic sk- does not match these)
            ("sk-ant-[A-Za-z0-9_-]{20,}", "sk-ant-[REDACTED]"),
            // OpenAI project keys
            ("sk-proj-[A-Za-z0-9_-]{20,}", "sk-proj-[REDACTED]"),
            // OpenAI service-account keys (hyphens; generic sk- misses these)
            ("sk-svcacct-[A-Za-z0-9_-]{20,}", "sk-svcacct-[REDACTED]"),
            // OpenRouter keys (hyphens; generic sk- misses these)
            ("sk-or-[A-Za-z0-9_-]{20,}", "sk-or-[REDACTED]"),
            // Stripe secret keys (underscores; generic sk- misses these)
            ("sk_live_[A-Za-z0-9]{20,}", "sk_live_[REDACTED]"),
            ("sk_test_[A-Za-z0-9]{20,}", "sk_test_[REDACTED]"),
            // OpenAI / generic sk- keys
            ("sk-[A-Za-z0-9]{20,}", "sk-[REDACTED]"),
            // GitHub personal access tokens
            ("ghp_[A-Za-z0-9]{36}", "ghp_[REDACTED]"),
            // GitHub OAuth access tokens
            ("gho_[A-Za-z0-9]{36}", "gho_[REDACTED]"),
            // GitHub App installation / server tokens
            ("ghs_[A-Za-z0-9]{36}", "ghs_[REDACTED]"),
            // GitHub App user-to-server tokens
            ("ghu_[A-Za-z0-9]{36}", "ghu_[REDACTED]"),
            // GitHub App refresh tokens
            ("ghr_[A-Za-z0-9]{36}", "ghr_[REDACTED]"),
            // GitHub fine-grained PATs
            ("github_pat_[A-Za-z0-9_]{20,}", "github_pat_[REDACTED]"),
            // xAI API keys
            ("xai-[A-Za-z0-9]{20,}", "xai-[REDACTED]"),
            // Slack bot / user / app tokens
            ("xox[baprs]-[A-Za-z0-9-]{10,}", "xox[REDACTED]"),
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
