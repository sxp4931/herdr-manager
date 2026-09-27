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
        let labeled: [(pattern: String, replacement: String)] = [
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
        ]
        // A whole value that is already a placeholder: `xai-[REDACTED]` from
        // a pattern above, or a bare `[REDACTED]`. Matching it again dropped
        // the label and counted one secret twice, and MCP redacts a tool's
        // already-redacted text a second time on the way out.
        //
        // The PEM replacement is `[REDACTED PRIVATE KEY]`. That string does
        // not contain `[REDACTED]` — there is no bracket after the word —
        // so the prefix list above does not cover it. `private_key` is now
        // an assignment name. Without listing the PEM token here, that
        // name would treat `[REDACTED` as a new value and leave
        // `PRIVATE KEY]`.
        let labels = labeled
            .map(\.replacement)
            .filter { $0.hasSuffix("[REDACTED]") }
            .map { NSRegularExpression.escapedPattern(for: String($0.dropLast("[REDACTED]".count))) }
        let placeholder = "(?:(?:\(labels.joined(separator: "|")))?\\[REDACTED\\]|\\[REDACTED PRIVATE KEY\\])(?![^\\s'\"&])"
        // The assignment placeholder treats `@` as part of a value, not as
        // the end of one. A URL password that is already `[REDACTED]` sits
        // immediately before `@host`. This lookahead is that whole token
        // plus the `@`, so the URL pattern does not count it again.
        let urlPlaceholder = "(?:(?:\(labels.joined(separator: "|")))?\\[REDACTED\\]|\\[REDACTED PRIVATE KEY\\])@"
        // HTTP Basic. Bearer names its own scheme, and an assignment
        // keyword never sees `Authorization: Basic dXNlcjpw…`, so the
        // base64 user:password reached the model. `Proxy-Authorization`
        // is the same header. A JSON value `"Authorization": "Basic …"`
        // is too, and so is the single-quoted form. The closing quote
        // stays, so a second pass still sees a boundary. The prefix
        // keeps its case. There may be no space between the scheme and
        // the token. The token is standard base64, at least 8 characters,
        // with or without padding. It has to carry a digit, `+`, `/`, or
        // `=`, or two capitals and two lowercase letters. That second
        // shape is `user:pass` (`dXNlcjpwYXNz`), which has no digit.
        // `Authorization: Basic authentication` and a single capital
        // (`Password`) stay. The classes are written out rather than
        // `(?i)`, so those capitals stay case-sensitive. A recognized
        // `xai-` or `ghp_` value was already replaced above. A hyphen or
        // an underscore is not part of this token.
        let proxy = "[Pp][Rr][Oo][Xx][Yy]"
        let authorization = "[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]"
        let basicWord = "[Bb][Aa][Ss][Ii][Cc]"
        let basicHeader = "(?:\(proxy)-)?\(authorization):\\s*\(basicWord)\\s*"
        let basicQuoted = "\"(?:\(proxy)-)?\(authorization)\"\\s*:\\s*\"\(basicWord)\\s*"
        let basicSingle = "'(?:\(proxy)-)?\(authorization)'\\s*:\\s*'\(basicWord)\\s*"
        let basicPrefix = "((?:^|[^A-Za-z0-9_-])(?:\(basicHeader)|\(basicQuoted)|\(basicSingle)))"
        let basicSignal =
            "(?=(?:[A-Za-z0-9+/]*[0-9+/=]|(?=(?:[A-Za-z0-9+/]*[A-Z]){2})(?=(?:[A-Za-z0-9+/]*[a-z]){2})[A-Za-z0-9+/]))"
        let basicToken =
            "(?:" +
            "(?:[A-Za-z0-9+/]{4}){2,}" +
            "|(?:[A-Za-z0-9+/]{4})+[A-Za-z0-9+/]{2}==" +
            "|(?:[A-Za-z0-9+/]{4})+[A-Za-z0-9+/]{3}=" +
            "|(?:[A-Za-z0-9+/]{4}){2,}[A-Za-z0-9+/]{2}" +
            "|(?:[A-Za-z0-9+/]{4}){2,}[A-Za-z0-9+/]{3}" +
            ")(?![A-Za-z0-9+/=])"
        let defs = labeled + [
            (basicPrefix + basicSignal + basicToken, "$1[REDACTED]"),
            // Generic assignments. A JSON key has a quote between the name
            // and the colon (`"api_key": "…"`); an env assignment does not
            // (`api_key=…`, `token: "…"`). `secret_key` and
            // `secret_access_key` (the suffix of `AWS_SECRET_ACCESS_KEY`)
            // are the same kind of name, and so are `private_key` and
            // `password_key`: the keyword is not the end until `_key` or
            // `_access_key`. A hyphen is the separator `api_key` already
            // accepts. The name still has to end there, so `secret_name`,
            // `secret_keys`, `token_key`, `private_keys`, and
            // `SECRET_ACCESS_KEY_ID` are not assignments. Bare `private`
            // is not a keyword. A double-quoted value keeps spaces and
            // apostrophes, and a single-quoted value keeps spaces. The
            // closing quote stays put: MCP redacts again on the way out,
            // and `}` is not a boundary the placeholder recognizes, so
            // eating the quote would count `[REDACTED]` a second time and
            // swallow the brace. An unquoted value stays one token and
            // still stops at whitespace or `&`.
            ("(?i)(api[_-]?key|secret(?:[_-]access)?[_-]key|private[_-]key|password[_-]key|secret|token|password)['\"]?\\s*[=:]\\s*(?:\"(?!\(placeholder))[^\"\\n]{8,}|'(?!\(placeholder))[^'\\n]{8,}|(?!\(placeholder))[^\\s'\"&]{8,})", "$1=[REDACTED]"),
            // A password in a URL is not an assignment. `DATABASE_URL`,
            // a Redis URL, and a git remote look like
            // `scheme://user:secret@host`, and the keyword list never
            // sees that secret. The user and the host stay. The password
            // is everything after the first colon of the userinfo, so a
            // colon inside it is still covered, and an empty user
            // (`redis://:secret@host`) is too. A password shorter than 8
            // characters stays, the same floor as an assignment. A value
            // that is already a placeholder is not a second secret. A
            // URL with no userinfo, including a host that only has a
            // port, is not a password.
            ("(?i)([a-z][a-z0-9+.-]*://[^:@\\s/]{0,256}:)(?!\(urlPlaceholder))[^\\s@]{8,}(?=@)", "$1[REDACTED]"),
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
