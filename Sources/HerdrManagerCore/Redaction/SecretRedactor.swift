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
        let beforeBearer: [(pattern: String, replacement: String)] = [
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
            // Stripe restricted keys. `sk_live_` does not name these, and
            // a restricted key is the server credential the dashboard
            // issues next to the secret key. The body is alphanumeric.
            // Twenty characters is the floor `sk_live_` already uses; a
            // shorter body stays. A letter, digit, or underscore glued
            // to the front is not the prefix: `network_live_` and
            // `mark_test_` contain these letters and are not keys.
            // Publishable `pk_live_` is not a secret and is not this
            // prefix. A `+` still ends the match.
            (
                "(?<![A-Za-z0-9_])rk_live_[A-Za-z0-9]{20,}",
                "rk_live_[REDACTED]"
            ),
            (
                "(?<![A-Za-z0-9_])rk_test_[A-Za-z0-9]{20,}",
                "rk_test_[REDACTED]"
            ),
            // Webhook signing secrets. Stripe and Standard Webhooks
            // (Svix, and the same prefix on a Clerk or Resend endpoint)
            // use `whsec_`. The body is base64, so `+`, `/`, and `=`
            // are part of the secret. The prefix stays. A body shorter
            // than 20 stays. `-` or `_` is not consumed: a snake_case
            // word is not a secret, and a body that continues with
            // either of those stays whole instead of leaving a tail.
            // A letter, digit, or underscore glued to the front is not
            // the prefix.
            (
                "(?<![A-Za-z0-9_])whsec_[A-Za-z0-9+/=]{20,}(?![A-Za-z0-9+/=_-])",
                "whsec_[REDACTED]"
            ),
            // OpenAI admin keys. `sk-proj-` and `sk-svcacct-` do not name
            // this prefix, and the generic `sk-` pattern stops at the
            // hyphen, so the body reached MCP tails and `herdmgr --json`.
            // An admin key manages the org. The body is the same
            // base64url alphabet as a project key. Twenty characters is
            // that floor; a shorter body stays. A letter, digit, or
            // underscore glued to the front is not the prefix. The case
            // is the one OpenAI issues.
            (
                "(?<![A-Za-z0-9_])sk-admin-[A-Za-z0-9_-]{20,}",
                "sk-admin-[REDACTED]"
            ),
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
            // GitLab credentials. The body is the secret. An assignment
            // named token already hides `GITLAB_TOKEN=…`; a pane log and
            // a CI trace print the token with no keyword. `glrt-` does
            // not match a `glrtr-` registration token: the hyphen sits
            // one character later. Twenty characters is the length
            // GitLab's own detector uses. A shorter string stays. A `.`
            // or `=` ends the match: those are not in this alphabet, and
            // a period is how a sentence ends.
            ("glpat-[A-Za-z0-9_-]{20,}", "glpat-[REDACTED]"),
            ("gldt-[A-Za-z0-9_-]{20,}", "gldt-[REDACTED]"),
            ("glrtr-[A-Za-z0-9_-]{20,}", "glrtr-[REDACTED]"),
            ("glrt-[A-Za-z0-9_-]{20,}", "glrt-[REDACTED]"),
            ("glcbt-[A-Za-z0-9_-]{20,}", "glcbt-[REDACTED]"),
            ("glptt-[A-Za-z0-9_-]{20,}", "glptt-[REDACTED]"),
            ("gloas-[A-Za-z0-9_-]{20,}", "gloas-[REDACTED]"),
            ("glagent-[A-Za-z0-9_-]{20,}", "glagent-[REDACTED]"),
            ("glsoat-[A-Za-z0-9_-]{20,}", "glsoat-[REDACTED]"),
            ("glffct-[A-Za-z0-9_-]{20,}", "glffct-[REDACTED]"),
            ("glimt-[A-Za-z0-9_-]{20,}", "glimt-[REDACTED]"),
            ("glft-[A-Za-z0-9_-]{20,}", "glft-[REDACTED]"),
            ("gltok-[A-Za-z0-9_-]{20,}", "gltok-[REDACTED]"),
            // npm publish tokens. Classic and granular access tokens are
            // `npm_` plus 36 base62 characters: that is the example on
            // the create-token response and the shape the delete path
            // accepts. An assignment named token already hides
            // `NPM_TOKEN=…` and `:_authToken=…`. A pane log and `npm
            // token` output print the token with no keyword, and that
            // token can publish packages. Thirty-six is the length npm
            // documents. A shorter body stays, and a longer one stays
            // whole, so a tail is not left behind. A letter, digit, or
            // underscore glued to the front is not the prefix. The
            // prefix is the lowercase form npm issues. A hyphen is not
            // in this alphabet.
            (
                "(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])",
                "npm_[REDACTED]"
            ),
            // PyPI upload tokens. The value is a macaroon whose header
            // is the fixed base64 `AgEIcHlwaS5vcmc` (`pypi.org`). An
            // assignment named password already hides `.pypirc`. Twine
            // and a pasted token have no keyword, and the token can
            // upload releases. Fifty characters is the floor under the
            // documented body. A shorter body stays. A body longer than
            // 1000 stays whole. `.` and `=` are not in the alphabet. A
            // letter, digit, or underscore glued to the front is not
            // the prefix.
            (
                "(?<![A-Za-z0-9_])pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{50,1000}(?![A-Za-z0-9_-])",
                "pypi-[REDACTED]"
            ),
            // Hugging Face user access tokens. The body is exactly 34
            // letters: that is the shape GitHub secret scanning and
            // gitleaks both accept, and a digit is not in it. An
            // assignment named token already hides `HF_TOKEN=…`. A pane
            // log and the CLI print the token with no keyword, and the
            // token can read or write private models. A shorter body
            // stays, and a longer one stays whole, so a tail is not
            // left behind. A letter, digit, or underscore glued to the
            // front is not the prefix. The prefix is the lowercase form
            // Hugging Face issues. A digit in the body stays whole.
            (
                "(?<![A-Za-z0-9_])hf_[A-Za-z]{34}(?![A-Za-z0-9])",
                "hf_[REDACTED]"
            ),
            // Hugging Face organization tokens. `api_org_` is the other
            // credential from the same issuer, with the same 34-letter
            // body. It is not an assignment name. The same boundaries
            // apply, including a body that contains a digit.
            (
                "(?<![A-Za-z0-9_])api_org_[A-Za-z]{34}(?![A-Za-z0-9])",
                "api_org_[REDACTED]"
            ),
            // RubyGems API keys. The generator is `rubygems_` plus
            // `SecureRandom.hex(24)`, which is 48 lowercase hex
            // characters, and that key can push gems. An assignment
            // named key already hides `GEM_HOST_API_KEY` and
            // `:rubygems_api_key:`. A credentials paste and `gem push`
            // print the key in the open. A shorter body stays, and a
            // longer one stays whole. A letter, digit, or underscore
            // glued to the front is not the prefix. Uppercase hex is
            // not what `SecureRandom.hex` writes. The 32-hex sample in
            // the API guide is not this length.
            (
                "(?<![A-Za-z0-9_])rubygems_[a-f0-9]{48}(?![A-Za-z0-9])",
                "rubygems_[REDACTED]"
            ),
            // xAI API keys
            ("xai-[A-Za-z0-9]{20,}", "xai-[REDACTED]"),
            // Slack app-level tokens (`xapp-1-<app>-<id>-<secret>`). The
            // older `xox[baprs]` pattern does not name this prefix. The
            // version is the single digit Slack issues. Each later
            // segment has a floor, so `xapp-` in a sentence stays. A
            // letter, digit, or underscore glued to the front is not
            // the prefix. The label stays, and the replacement is a
            // placeholder.
            (
                "(?i)(?<![A-Za-z0-9_])xapp-[0-9]-[A-Za-z0-9]{8,}-[0-9]{8,}-[A-Za-z0-9]{32,}",
                "xapp-[REDACTED]"
            ),
            // Rotated config access tokens. The body is base64, so it
            // contains `+`, `/`, and `=`. `xox[baprs]` matches the inner
            // `xoxb-` or `xoxp-` and stops at the first of those, which
            // leaves the tail. This pattern is above that one and takes
            // the whole token. Twenty characters is the floor; a shorter
            // body stays. The refresh token below is `xoxe-`, not
            // `xoxe.xox`.
            (
                "(?i)(?<![A-Za-z0-9_])xoxe\\.xox[bp]-[A-Za-z0-9+/=_-]{20,}",
                "xoxe.xox[REDACTED]"
            ),
            // Config refresh tokens, and the `xoxe-` value on a Slack
            // file URL. The refresh token mints a new access token. A
            // body shorter than 20 stays. `+`, `/`, and `=` are part of
            // the secret, same as the access token above.
            (
                "(?i)(?<![A-Za-z0-9_])xoxe-[A-Za-z0-9+/=_-]{20,}",
                "xoxe-[REDACTED]"
            ),
            // Web-client session tokens. `c` is not in `xox[baprs]`. The
            // body is the same alphabet as a bot token. Twenty-four
            // characters is the floor, so a short `xoxc-` stays. A
            // percent-encoded `xoxd-` cookie is not this shape.
            (
                "(?i)(?<![A-Za-z0-9_])xoxc-[A-Za-z0-9-]{24,}",
                "xoxc-[REDACTED]"
            ),
            // Slack bot, user, and legacy tokens (`xoxb`, `xoxp`, `xoxa`,
            // `xoxr`, `xoxs`). A `+`, `/`, or `=` still ends this match.
            // Rotation tokens are taken whole by the patterns above.
            ("xox[baprs]-[A-Za-z0-9-]{10,}", "xox[REDACTED]"),
            // Slack incoming, workflow, and trigger webhooks. The path
            // is the credential: posting to it writes into the workspace,
            // and there is no separate token. `xoxb-` does not match this
            // URL, and `SLACK_WEBHOOK_URL` is not an assignment keyword,
            // so the secret reached MCP tails and `herdmgr --json`. The
            // host stays. The replacement is a placeholder, so a second
            // pass counts nothing and `token=<url>` does not take the
            // host. The scheme is optional on the way in and written
            // back as https. The last segment is at least 16 characters;
            // a shorter one stays. A segment shorter than 8 stays. A
            // letter glued to the front is not this host. GovSlack is
            // the same path on `hooks.slack-gov.com`.
            (
                "(?i)(?<![A-Za-z0-9.])(?:https?://)?hooks\\.slack\\.com/(?:services|triggers|workflows)/(?:[A-Za-z0-9_-]{8,64}/){1,4}[A-Za-z0-9_-]{16,128}",
                "https://hooks.slack.com/[REDACTED]"
            ),
            (
                "(?i)(?<![A-Za-z0-9.])(?:https?://)?hooks\\.slack-gov\\.com/(?:services|triggers|workflows)/(?:[A-Za-z0-9_-]{8,64}/){1,4}[A-Za-z0-9_-]{16,128}",
                "https://hooks.slack-gov.com/[REDACTED]"
            ),
            // Discord incoming webhooks. The path is the credential: a
            // POST writes into the channel. The id is a snowflake (17 to
            // 20 digits, the width of a uint64). The token is at least
            // 20 characters; the issued token is longer, and a shorter
            // one stays. canary, ptb, and the legacy discordapp host are
            // the same URL, including `/api/v10`. The scheme is optional
            // on the way in. The host written back is one placeholder, so
            // a second pass counts nothing and `token=<url>` does not
            // take it. A letter or dot glued to the front is not this
            // host. A period or a query string after the token stays.
            (
                "(?i)(?<![A-Za-z0-9.])(?:https?://)?(?:(?:canary|ptb)\\.)?discord(?:app)?\\.com/api(?:/v[0-9]{1,2})?/webhooks/[0-9]{17,20}/[A-Za-z0-9_-]{20,}",
                "https://discord.com/api/webhooks/[REDACTED]"
            ),
            // Teams connector URLs. The path is the credential. The
            // tenant label varies, so the host written back is the fixed
            // suffix and the path is gone. `webhook` and `webhookb2` are
            // the two path spellings on this host. The ids are the GUID,
            // `@`, GUID, `IncomingWebhook`, 32 hex, GUID shape Teams
            // issues. A docs path without those ids stays. A host that
            // only continues past `.com` is not this host.
            (
                "(?i)(?<![A-Za-z0-9.])(?:https?://)?[a-z0-9][a-z0-9.-]{0,80}\\.webhook\\.office\\.com/webhook(?:b2)?/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/IncomingWebhook/[0-9a-f]{32}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                "https://webhook.office.com/[REDACTED]"
            ),
            (
                "(?i)(?<![A-Za-z0-9.])(?:https?://)?outlook\\.office\\.com/webhook/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/IncomingWebhook/[0-9a-f]{32}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                "https://outlook.office.com/[REDACTED]"
            ),
            (
                "(?i)(?<![A-Za-z0-9.])(?:https?://)?outlook\\.office365\\.com/webhook/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/IncomingWebhook/[0-9a-f]{32}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                "https://outlook.office365.com/[REDACTED]"
            ),
            // Teams Workflows, and any Logic App HTTP trigger: the URL
            // is the credential, and the secret is the `sig` query.
            // `sig` is not an assignment keyword. The workflow id and
            // the trigger path are what keep this from matching an
            // unrelated `sig=`. The sig is at least 20 characters and
            // stops at `&` or whitespace, so a later query parameter
            // stays. A shorter sig stays.
            (
                "(?i)(?<![A-Za-z0-9.])(?:https?://)?[a-z0-9][a-z0-9.-]{0,80}\\.logic\\.azure\\.com(?::[0-9]{2,5})?/workflows/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/triggers/[A-Za-z0-9_%.-]{1,80}/paths/invoke\\?[^\\t\\r\\n ]*\\bsig=[^\\t\\r\\n &]{20,}",
                "https://logic.azure.com/[REDACTED]"
            ),
            // AWS access key IDs
            ("AKIA[0-9A-Z]{16}", "AKIA[REDACTED]"),
            // Google API keys. Maps, Firebase, and YouTube put `AIza`
            // plus 35 characters in `?key=` and in `current_key`.
            // Neither name is an assignment keyword, so the value
            // reached MCP tails and `herdmgr --json`. The body is
            // exactly 35: a shorter one stays, and a longer one stays
            // whole so a tail is not left behind. A letter, digit, or
            // underscore glued to the front is not the prefix. The
            // case is the one Google issues. A temporary `ASIA` access
            // key id is not this prefix.
            (
                "(?<![A-Za-z0-9_])AIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_-])",
                "AIza[REDACTED]"
            ),
            // Google OAuth client secrets. `GOCSPX-` plus 28 is the
            // value in `client_secret.json`, and the body includes
            // `-`. `client_secret` is already an assignment; this
            // keeps the prefix and also catches a bare paste. A
            // shorter body stays unless that assignment takes it. A
            // longer body stays whole. A letter, digit, or underscore
            // glued to the front is not the prefix.
            (
                "(?<![A-Za-z0-9_])GOCSPX-[0-9A-Za-z_-]{28}(?![A-Za-z0-9_-])",
                "GOCSPX-[REDACTED]"
            ),
        ]
        // Compact JWS or JWE, then a PEM block. Both stay after bearer:
        // a JWT written after the scheme has to be one redaction, and
        // the bearer pattern is what consumes the dots.
        let afterBearer: [(pattern: String, replacement: String)] = [
            // Compact JWS or JWE with no scheme. The header is base64url
            // of JSON, so the token starts with `eyJ`. Each segment is at
            // least 10 characters and there are at least three, so a short
            // dotted example (`.test.sig`) is not this token. An empty
            // segment (`..`) stays: the piece between the dots is missing.
            ("(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}(?:\\.[A-Za-z0-9_-]{10,}){2,}", "eyJ[REDACTED]"),
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
        //
        // `Bearer [REDACTED]` is the opaque-token replacement. It is not
        // in `beforeBearer` because the scheme pattern is built from this
        // same list: a key that was already replaced must not be counted
        // again when the header says Bearer.
        let labelSources = beforeBearer.map(\.replacement)
            + ["Bearer [REDACTED]"]
            + afterBearer.map(\.replacement)
        let labels = labelSources
            .filter { $0.hasSuffix("[REDACTED]") }
            .map { NSRegularExpression.escapedPattern(for: String($0.dropLast("[REDACTED]".count))) }
        let redactedToken =
            "(?:(?:\(labels.joined(separator: "|")))?\\[REDACTED\\]|\\[REDACTED PRIVATE KEY\\])"
        let placeholder = redactedToken + "(?![^\\s'\"&])"
        // The assignment placeholder treats `@` as part of a value, not as
        // the end of one. A URL password that is already `[REDACTED]` sits
        // immediately before `@host`. This lookahead is that whole token
        // plus the `@`, so the URL pattern does not count it again.
        let urlPlaceholder = redactedToken + "@"
        // Bearer scheme. HTTP treats the scheme as case-insensitive, and
        // pane logs paste `authorization: bearer …`. A letter, digit, or
        // underscore glued to the front is not the scheme (`notbearer`
        // stays). The token alphabet includes `.`, so a JWT after this
        // word is one redaction and the payload is not left for the
        // pattern below. A token a pattern above already replaced is
        // `prefix[REDACTED]`. Matching the prefix again turned
        // `Bearer xai-[REDACTED]` into `Bearer [REDACTED][REDACTED]` and
        // counted one secret twice. The lookahead is the placeholder
        // without the assignment boundary, so a period after the token
        // still keeps the label.
        let bearer: (pattern: String, replacement: String) = (
            pattern: "(?<![A-Za-z0-9_])[Bb][Ee][Aa][Rr][Ee][Rr]\\s+(?!\(redactedToken))[A-Za-z0-9\\-._~+/]+=*",
            replacement: "Bearer [REDACTED]"
        )
        let labeled = beforeBearer + [bearer] + afterBearer
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
        // `api[_-]?key` already makes the separator optional, so `apiKey`
        // is an assignment. JSON and the AWS CLI write the other names
        // the same way, with no `_` or `-`: `secretKey`, `SecretAccessKey`,
        // `privateKey`, `passwordKey`. The separator may be absent. The
        // name still has to end on that keyword, so `secretKeys`,
        // `privateKeys`, `passwordKeyboard`, and `secretAccessKeyId` are
        // not assignments. `secretary` has no `key`.
        let keyword =
            "api[_-]?key|secret[_-]?access[_-]?key|secret[_-]?key|private[_-]?key|password[_-]?key|secret|token|password"
        let defs = labeled + [
            (basicPrefix + basicSignal + basicToken, "$1[REDACTED]"),
            // Generic assignments. A JSON key has a quote between the name
            // and the colon (`"api_key": "…"`); an env assignment does not
            // (`api_key=…`, `token: "…"`). `secret_key` and
            // `secret_access_key` (the suffix of `AWS_SECRET_ACCESS_KEY`)
            // are the same kind of name, and so are `private_key` and
            // `password_key`. The separator may be absent (`SecretAccessKey`,
            // `privateKey`); a hyphen is still the separator `api_key`
            // already accepts. The name still has to end there, so
            // `secret_name`, `secret_keys`, `secretKeys`,
            // `secretAccessKeyId`, `token_key`, `private_keys`, and
            // `SECRET_ACCESS_KEY_ID` are not assignments. Bare `private`
            // is not a keyword. A double-quoted value keeps spaces and
            // apostrophes, and a single-quoted value keeps spaces. The
            // closing quote stays put: MCP redacts again on the way out,
            // and `}` is not a boundary the placeholder recognizes, so
            // eating the quote would count `[REDACTED]` a second time and
            // swallow the brace. An unquoted value stays one token and
            // still stops at whitespace or `&`.
            //
            // A URL username is not that key. `https://x-access-token:…@github.com`
            // and `https://gitlab-ci-token:…@gitlab.com` used to match
            // `token:` and the value ran through `@`, so the host left
            // with the secret. The guard is only `://`, at most 39
            // username characters, a keyword, `:`, then 8 non-space
            // characters and `@`. 39 covers GitHub's username limit when
            // the keyword is `token`. `@` is still not the end of an
            // ordinary value: `token=xai-…@leftover` is still consumed
            // through the `@`, because treating `@` as a boundary would
            // publish the tail.
            // An `=` is still an assignment. A password the URL pattern
            // leaves (shorter than 8, or cut by a raw `@`) still assigns,
            // so those characters are not published. A lookbehind this
            // engine rejects falls back to the unguarded pattern. Dropping
            // the pattern would stop redacting every assignment.
            (Self.assignmentPattern(keyword: keyword, placeholder: placeholder), "$1=[REDACTED]"),
            // A password in a URL is not an assignment. `DATABASE_URL`,
            // a Redis URL, and a git remote look like
            // `scheme://user:secret@host`. A username that ends in a
            // keyword is declined by the guard above when this password
            // is at least 8 characters and has no raw `@`, which is what
            // this pattern redacts. The user and the host stay. The password
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

    /// The assignment pattern, with the URL-username guard when this
    /// engine accepts that lookbehind.
    private static func assignmentPattern(keyword: String, placeholder: String) -> String {
        let body =
            "(\(keyword))['\"]?\\s*[=:]\\s*(?:\"(?!\(placeholder))[^\"\\n]{8,}|'(?!\(placeholder))[^'\\n]{8,}|(?!\(placeholder))[^\\s'\"&]{8,})"
        let guarded =
            "(?i)(?!(?<=://[^:@\\s/]{0,39})(?:\(keyword)):[^\\s@]{8,}@)\(body)"
        if (try? NSRegularExpression(pattern: guarded, options: [])) != nil {
            return guarded
        }
        return "(?i)\(body)"
    }

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
