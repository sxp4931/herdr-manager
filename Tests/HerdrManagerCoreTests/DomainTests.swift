import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - AgentStatus Codable Tests

@Suite("AgentStatus Codable")
struct AgentStatusTests {
    @Test("Round-trip encode/decode for known statuses")
    func roundTrip() async throws {
        let statuses: [AgentStatus] = [.idle, .working, .blocked, .done, .unknown]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in statuses {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(AgentStatus.self, from: data)
            #expect(decoded == status)
        }
    }

    @Test("Decode from lowercase string")
    func decodeFromString() async throws {
        let json = #""blocked""#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AgentStatus.self, from: data)
        #expect(decoded == .blocked)
    }

    @Test("Unknown string maps to .unknown")
    func unknownString() async throws {
        let json = #""something_new""#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AgentStatus.self, from: data)
        #expect(decoded == .unknown)
    }
}

// MARK: - AgentID Tests

@Suite("AgentID")
struct AgentIDTests {
    @Test("Format workspaceId:paneId")
    func format() {
        let id = AgentID(workspaceId: "w5", paneId: "p1")
        #expect(id.raw == "w5:p1")
        #expect(id.workspaceId == "w5")
        #expect(id.paneId == "p1")
    }

    @Test("Parse from raw string")
    func parseRaw() {
        let id = AgentID("w3:p7")
        #expect(id.workspaceId == "w3")
        #expect(id.paneId == "p7")
    }

    @Test("Equality and hashing")
    func equality() {
        let a = AgentID("w1:p1")
        let b = AgentID(workspaceId: "w1", paneId: "p1")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}

// MARK: - SecretRedactor Tests

@Suite("SecretRedactor")
struct SecretRedactorTests {
    @Test("Redacts OpenAI sk- keys")
    func redactsSkKey() {
        let redactor = SecretRedactor()
        let text = "my key is sk-abcdefghijklmnopqrstuvwxyz1234 ok"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        #expect(result.redactedText.contains("sk-[REDACTED]"))
    }

    @Test("Redacts GitHub tokens")
    func redactsGhp() {
        let redactor = SecretRedactor()
        let text = "token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("ghp_ABCDEF"))
    }

    @Test("Redacts AWS keys")
    func redactsAKIA() {
        let redactor = SecretRedactor()
        let text = "aws_key=AKIAIOSFODNN7EXAMPLE"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("AKIAIOSFODNN7"))
    }

    @Test("Redacts Bearer tokens")
    func redactsBearer() {
        let redactor = SecretRedactor()
        let text = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.test.sig"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(result.redactedText.contains("Bearer [REDACTED]"))
    }

    @Test("A lowercase bearer scheme and a raw JWT are redacted once")
    func redactsBearerCaseAndRawJWT() {
        let redactor = SecretRedactor()
        let opaque = "opaquetoken" + "1234567890"
        let jwt = "eyJ" + "aaaaaaaaaa" + "." + "bbbbbbbbbb" + "." + "cccccccccc"

        let lower = redactor.redact("Authorization: bearer \(opaque)")
        #expect(lower.redactedText == "Authorization: Bearer [REDACTED]")
        #expect(lower.redactionCount == 1)
        #expect(!lower.redactedText.contains(opaque))
        let lowerAgain = redactor.redact(lower.redactedText)
        #expect(lowerAgain.redactedText == lower.redactedText)
        #expect(lowerAgain.redactionCount == 0)

        let upper = redactor.redact("Proxy-Authorization: BEARER \(opaque)")
        #expect(upper.redactedText == "Proxy-Authorization: Bearer [REDACTED]")
        #expect(upper.redactionCount == 1)

        // The scheme and the token may sit inside a JSON string. The
        // closing quote stays, so a second pass still sees a boundary.
        let quoted = redactor.redact(#"{"Authorization": "bearer \#(opaque)"}"#)
        #expect(quoted.redactedText == #"{"Authorization": "Bearer [REDACTED]"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        // A JWT after the scheme is the bearer token, not a second secret.
        let wrapped = redactor.redact("authorization: bearer \(jwt)")
        #expect(wrapped.redactedText == "authorization: Bearer [REDACTED]")
        #expect(wrapped.redactionCount == 1)
        #expect(!wrapped.redactedText.contains("aaaaaaaaaa"))
        #expect(!wrapped.redactedText.contains("cccccccccc"))

        let raw = redactor.redact("session \(jwt) done")
        #expect(raw.redactedText == "session eyJ[REDACTED] done")
        #expect(raw.redactionCount == 1)
        #expect(!raw.redactedText.contains("bbbbbbbbbb"))
        let rawAgain = redactor.redact(raw.redactedText)
        #expect(rawAgain.redactedText == raw.redactedText)
        #expect(rawAgain.redactionCount == 0)

        // The whole value is the token, so the assignment does not count it again.
        let assigned = redactor.redact("token=\(jwt)")
        #expect(assigned.redactedText == "token=eyJ[REDACTED]")
        #expect(assigned.redactionCount == 1)
        let assignedJSON = redactor.redact(#"{"id_token": "\#(jwt)"}"#)
        #expect(assignedJSON.redactedText == #"{"id_token": "eyJ[REDACTED]"}"#)
        #expect(assignedJSON.redactionCount == 1)
        let assignedAgain = redactor.redact(assignedJSON.redactedText)
        #expect(assignedAgain.redactionCount == 0)

        let pair = redactor.redact("\(jwt) \(jwt)")
        #expect(pair.redactionCount == 2)
        #expect(pair.redactedText == "eyJ[REDACTED] eyJ[REDACTED]")

        // Five segments are one compact JWE, not three tokens.
        let jwe = redactor.redact(jwt + "." + "dddddddddd" + "." + "eeeeeeeeee")
        #expect(jwe.redactedText == "eyJ[REDACTED]")
        #expect(jwe.redactionCount == 1)
        let jweAgain = redactor.redact(jwe.redactedText)
        #expect(jweAgain.redactionCount == 0)

        // Below the segment floor, or missing a segment, this is not a JWT.
        // The short dotted example still needs the word Bearer. An empty
        // segment (`..`) is not one either.
        let shortSegment = "eyJ" + "aaaaaaaaa" + "." + "bbbbbbbbbb" + "." + "cccccccccc"
        let twoSegments = "eyJ" + "aaaaaaaaaa" + "." + "bbbbbbbbbb"
        let dottedExample = "eyJhbGciOiJIUzI1NiJ9.test.sig"
        let emptySegment = "eyJ" + "aaaaaaaaaa" + ".." + "bbbbbbbbbb" + "." + "cccccccccc" + "." + "dddddddddd"
        let glued = "xx" + jwt
        let gluedScheme = "notbearer " + opaque
        for kept in [shortSegment, twoSegments, dottedExample, emptySegment, glued, gluedScheme] {
            let result = redactor.redact(kept)
            #expect(result.redactedText == kept)
            #expect(result.redactionCount == 0)
        }
    }

    @Test("No false positives on clean text")
    func cleanText() {
        let redactor = SecretRedactor()
        let text = "Hello world, this is a normal message."
        let result = redactor.redact(text)
        #expect(result.redactionCount == 0)
        #expect(result.redactedText == text)
    }

    @Test("Redacts xAI API keys")
    func redactsXAIKey() {
        let redactor = SecretRedactor()
        let text = "export XAI_API_KEY=xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(result.redactedText.contains("xai-[REDACTED]"))
    }

    @Test("Redacts GitHub fine-grained PATs")
    func redactsGithubPat() {
        let redactor = SecretRedactor()
        let text = "token=github_pat_11AAAAAAA0123456789abcdefghijklmnopqrstuv"
        let result = redactor.redact(text)
        #expect(result.redactionCount >= 1)
        #expect(!result.redactedText.contains("11AAAAAAA0123456789"))
        #expect(result.redactedText.contains("github_pat_[REDACTED]") || result.redactedText.contains("token=[REDACTED]"))
    }

    @Test("Redacts Anthropic and OpenAI project keys that the generic sk- pattern misses")
    func redactsHyphenatedSkKeys() {
        let redactor = SecretRedactor()
        let ant = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let proj = "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let result = redactor.redact("ant=\(ant) proj=\(proj)")
        #expect(result.redactionCount >= 2)
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        #expect(result.redactedText.contains("sk-ant-[REDACTED]"))
        #expect(result.redactedText.contains("sk-proj-[REDACTED]"))
    }

    @Test("Redacts GitHub OAuth and App server tokens")
    func redactsGithubOAuthAndAppTokens() {
        let redactor = SecretRedactor()
        let gho = "gho_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let ghs = "ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let result = redactor.redact("oauth=\(gho) app=\(ghs)")
        #expect(result.redactionCount >= 2)
        #expect(!result.redactedText.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"))
        #expect(result.redactedText.contains("gho_[REDACTED]"))
        #expect(result.redactedText.contains("ghs_[REDACTED]"))
    }

    @Test("Redacts OpenAI service-account keys and GitHub user-to-server tokens")
    func redactsServiceAccountAndGithubUserTokens() {
        let redactor = SecretRedactor()
        let svc = "sk-svcacct-abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let ghu = "ghu_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let ghr = "ghr_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let result = redactor.redact("svc=\(svc) user=\(ghu) refresh=\(ghr)")
        #expect(result.redactionCount >= 3)
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        #expect(!result.redactedText.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"))
        #expect(result.redactedText.contains("sk-svcacct-[REDACTED]"))
        #expect(result.redactedText.contains("ghu_[REDACTED]"))
        #expect(result.redactedText.contains("ghr_[REDACTED]"))
    }

    @Test("Redacts OpenRouter, Stripe, and Slack tokens the generic sk- pattern misses")
    func redactsOpenRouterStripeAndSlackTokens() {
        let redactor = SecretRedactor()
        // Build fixtures via concatenation so the file has no contiguous secret-shaped literals
        // (MCP/GitHub secret scanners block sk_live_ / xoxb- string literals).
        let openRouter = "sk" + "-or-v1-" + "abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let stripeLive = "sk" + "_live_" + "abcdefghijklmnopqrstuvwxyz0123"
        let slack = "xox" + "b-" + "123456789012-" + "abcdefghijklmnopqrstuvwx"
        let result = redactor.redact("or=\(openRouter) stripe=\(stripeLive) slack=\(slack)")
        #expect(result.redactionCount >= 3)
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123"))
        #expect(!result.redactedText.contains("abcdefghijklmnopqrstuvwx"))
        #expect(result.redactedText.contains("sk-or-[REDACTED]"))
        #expect(result.redactedText.contains("sk" + "_live_[REDACTED]"))
        #expect(result.redactedText.contains("xox[REDACTED]"))
    }

    @Test("A key after api_key= keeps its own label and counts once")
    func labeledKeyAfterAssignmentCountsOnce() {
        let redactor = SecretRedactor()
        let result = redactor.redact("export XAI_API_KEY=xai-abcdefghijklmnopqrstuvwxyz0123456789")
        #expect(result.redactedText == "export XAI_API_KEY=xai-[REDACTED]")
        #expect(result.redactionCount == 1)
    }

    @Test("Redacting already-redacted text changes and counts nothing")
    func redactingTwiceIsANoOp() {
        // MCP redacts a tool's text, then redacts the result again on the way out.
        let redactor = SecretRedactor()
        let once = redactor.redact("token=hunter2hunter2 GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij")
        let twice = redactor.redact(once.redactedText)
        #expect(once.redactedText == "token=[REDACTED] GITHUB_TOKEN=ghp_[REDACTED]")
        #expect(twice.redactedText == once.redactedText)
        #expect(twice.redactionCount == 0)
    }

    @Test("Redacts a quoted JSON assignment the env pattern used to skip")
    func redactsQuotedJSONAssignment() {
        let redactor = SecretRedactor()
        let once = redactor.redact(
            #"{"api_key": "supersecretvalue", "token": "anothersecretvalue"}"#
        )
        #expect(once.redactedText == #"{"api_key=[REDACTED]", "token=[REDACTED]"}"#)
        #expect(once.redactionCount == 2)
        #expect(!once.redactedText.contains("supersecretvalue"))
        #expect(!once.redactedText.contains("anothersecretvalue"))
        let twice = redactor.redact(once.redactedText)
        #expect(twice.redactedText == once.redactedText)
        #expect(twice.redactionCount == 0)

        // No space, single quotes, a space before the colon, and a line
        // break before the value are the same assignment.
        #expect(
            redactor.redact(#"{"api_key":"supersecretvalue"}"#).redactedText
                == #"{"api_key=[REDACTED]"}"#
        )
        #expect(
            redactor.redact("{'api_key': 'supersecretvalue'}").redactedText
                == "{'api_key=[REDACTED]'}"
        )
        #expect(
            redactor.redact(#""api_key" : "supersecretvalue""#).redactedText
                == #""api_key=[REDACTED]""#
        )
        #expect(
            redactor.redact("\"api_key\":\n  \"supersecretvalue\"").redactedText
                == #""api_key=[REDACTED]""#
        )
        #expect(
            redactor.redact("\"api_key\":\r\n  \"supersecretvalue\"").redactedText
                == #""api_key=[REDACTED]""#
        )
        // The closing quote stays, which is what keeps a second pass from
        // treating the placeholder as a new value.
        #expect(redactor.redact("token=\"hunter2hunter2\"").redactedText == "token=[REDACTED]\"")
        #expect(redactor.redact("token='hunter2hunter2'").redactedText == "token=[REDACTED]'")
    }

    @Test("A quoted passphrase keeps its spaces and apostrophes")
    func redactsQuotedPassphrase() {
        let redactor = SecretRedactor()
        let phrase = "correct horse's battery staple"
        let once = redactor.redact(#"{"password": "\#(phrase)"}"#)
        #expect(once.redactedText == #"{"password=[REDACTED]"}"#)
        #expect(once.redactionCount == 1)
        #expect(!once.redactedText.contains("horse"))
        let twice = redactor.redact(once.redactedText)
        #expect(twice.redactedText == once.redactedText)
        #expect(twice.redactionCount == 0)

        #expect(
            redactor.redact("password=\"\(phrase)\"").redactedText
                == "password=[REDACTED]\""
        )
        #expect(
            redactor.redact("{'password': 'correct horse battery staple'}").redactedText
                == "{'password=[REDACTED]'}"
        )
        // The keyword is a suffix, so the prefix stays on the label.
        #expect(
            redactor.redact(
                #"{"access_token": "supersecretvalue", "client_secret": "anothersecretvalue"}"#
            ).redactedText
                == #"{"access_token=[REDACTED]", "client_secret=[REDACTED]"}"#
        )
        #expect(
            redactor.redact(
                #"{"apiKey": "supersecretvalue", "api-key": "anothersecretvalue"}"#
            ).redactedText
                == #"{"apiKey=[REDACTED]", "api-key=[REDACTED]"}"#
        )
    }

    @Test("A recognized key inside JSON keeps its own label and counts once")
    func recognizedKeyInsideJSONCountsOnce() {
        let redactor = SecretRedactor()
        let key = "xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let once = redactor.redact(
            "{\"api_key\": \"\(key)\", \"token\": \"supersecretvalue\"}"
        )
        #expect(once.redactedText == #"{"api_key": "xai-[REDACTED]", "token=[REDACTED]"}"#)
        #expect(once.redactionCount == 2)
        #expect(!once.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!once.redactedText.contains("supersecretvalue"))
        let twice = redactor.redact(once.redactedText)
        #expect(twice.redactedText == once.redactedText)
        #expect(twice.redactionCount == 0)
    }

    @Test("Ordinary JSON and a short quoted value stay")
    func leavesOrdinaryJSON() {
        let redactor = SecretRedactor()
        let clean = #"{"name": "claude", "status": "working", "max_tokens": 123456789}"#
        let cleanResult = redactor.redact(clean)
        #expect(cleanResult.redactionCount == 0)
        #expect(cleanResult.redactedText == clean)
        #expect(redactor.redact(#""token": "hunter2""#).redactedText == #""token": "hunter2""#)
        #expect(redactor.redact(#""token": "1234567""#).redactedText == #""token": "1234567""#)
        #expect(redactor.redact(#""token": "12345678""#).redactedText == #""token=[REDACTED]""#)
        #expect(redactor.redact(#""token": "[REDACTED]""#).redactionCount == 0)
        #expect(redactor.redact("The token is not a secret.").redactionCount == 0)
    }

    @Test("Redacts secret_key and AWS_SECRET_ACCESS_KEY without taking neighboring names")
    func redactsSecretKeyAndSecretAccessKey() {
        let redactor = SecretRedactor()
        let mixed = "abcd" + "+efg/" + "hijklmnop"
        let env = redactor.redact(
            "export SECRET_KEY=supersecretvalue AWS_SECRET_ACCESS_KEY=\(mixed)"
        )
        #expect(env.redactedText == "export SECRET_KEY=[REDACTED] AWS_SECRET_ACCESS_KEY=[REDACTED]")
        #expect(env.redactionCount == 2)
        #expect(!env.redactedText.contains("supersecretvalue"))
        #expect(!env.redactedText.contains("+efg/"))
        let envAgain = redactor.redact(env.redactedText)
        #expect(envAgain.redactedText == env.redactedText)
        #expect(envAgain.redactionCount == 0)

        let json = redactor.redact(
            #"{"aws_secret_access_key": "supersecretvalue", "secret_key": "anothersecretvalue", "secret_name": "keepthisvalue", "token_count": 12345678}"#
        )
        #expect(
            json.redactedText
                == #"{"aws_secret_access_key=[REDACTED]", "secret_key=[REDACTED]", "secret_name": "keepthisvalue", "token_count": 12345678}"#
        )
        #expect(json.redactionCount == 2)
        #expect(!json.redactedText.contains("supersecretvalue"))
        #expect(!json.redactedText.contains("anothersecretvalue"))
        #expect(json.redactedText.contains("keepthisvalue"))
        let jsonAgain = redactor.redact(json.redactedText)
        #expect(jsonAgain.redactedText == json.redactedText)
        #expect(jsonAgain.redactionCount == 0)

        // A hyphen is the same separator api_key already accepts. A prefix
        // before secret_key stays on the label, and the captured name keeps
        // its case.
        #expect(
            redactor.redact("secret-key=supersecretvalue secret-access-key=anothersecretvalue").redactedText
                == "secret-key=[REDACTED] secret-access-key=[REDACTED]"
        )
        #expect(
            redactor.redact("my_secret_key=supersecretvalue").redactedText
                == "my_secret_key=[REDACTED]"
        )
        #expect(redactor.redact("secret_key=12345678").redactedText == "secret_key=[REDACTED]")
        #expect(
            redactor.redact("Secret_Access_Key=supersecretvalue").redactedText
                == "Secret_Access_Key=[REDACTED]"
        )
        #expect(
            redactor.redact(#"{"secret_key": "correct horse's battery"}"#).redactedText
                == #"{"secret_key=[REDACTED]"}"#
        )

        // The name has to end on the keyword. A longer identifier, a plural,
        // a different word, and a 7-character value stay.
        let kept = [
            "secret_name=supersecretvalue",
            "secret_keys=supersecretvalue",
            "AWS_SECRET_ACCESS_KEY_ID=supersecretvalue",
            "secretary=supersecretvalue",
            "token_count: 12345678",
            "secret_key=1234567",
            #"{"secret_name": "supersecretvalue"}"#,
        ]
        for line in kept {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line)")
            #expect(result.redactedText == line)
        }

        // A recognized token keeps its own label. The compound name does
        // not take a second count off the placeholder.
        let key = "xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let labeled = redactor.redact(#"{"secret_key": "\#(key)"}"#)
        #expect(labeled.redactedText == #"{"secret_key": "xai-[REDACTED]"}"#)
        #expect(labeled.redactionCount == 1)
        #expect(!labeled.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let labeledAgain = redactor.redact(labeled.redactedText)
        #expect(labeledAgain.redactedText == labeled.redactedText)
        #expect(labeledAgain.redactionCount == 0)
    }

    @Test("Redacts private_key and password_key without taking token_key or a bare private")
    func redactsPrivateKeyAndPasswordKey() {
        let redactor = SecretRedactor()
        let env = redactor.redact(
            "export PRIVATE_KEY=MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSj PASSWORD_KEY=anothersecretvalue"
        )
        #expect(env.redactedText == "export PRIVATE_KEY=[REDACTED] PASSWORD_KEY=[REDACTED]")
        #expect(env.redactionCount == 2)
        #expect(!env.redactedText.contains("MIIEv"))
        #expect(!env.redactedText.contains("anothersecretvalue"))
        let envAgain = redactor.redact(env.redactedText)
        #expect(envAgain.redactedText == env.redactedText)
        #expect(envAgain.redactionCount == 0)

        let json = redactor.redact(
            #"{"private_key": "supersecretvalue", "password_key": "anothersecretvalue", "private_keys": "keepthisvalue", "token_key": "keepthistoo", "PRIVATE_KEY_ID": "stillkeep"}"#
        )
        #expect(
            json.redactedText
                == #"{"private_key=[REDACTED]", "password_key=[REDACTED]", "private_keys": "keepthisvalue", "token_key": "keepthistoo", "PRIVATE_KEY_ID": "stillkeep"}"#
        )
        #expect(json.redactionCount == 2)
        #expect(!json.redactedText.contains("supersecretvalue"))
        #expect(!json.redactedText.contains("anothersecretvalue"))
        #expect(json.redactedText.contains("keepthisvalue"))
        #expect(json.redactedText.contains("keepthistoo"))
        #expect(json.redactedText.contains("stillkeep"))
        let jsonAgain = redactor.redact(json.redactedText)
        #expect(jsonAgain.redactedText == json.redactedText)
        #expect(jsonAgain.redactionCount == 0)

        #expect(
            redactor.redact("private-key=supersecretvalue password-key=anothersecretvalue").redactedText
                == "private-key=[REDACTED] password-key=[REDACTED]"
        )
        #expect(redactor.redact("my_private_key=supersecretvalue").redactedText == "my_private_key=[REDACTED]")
        #expect(redactor.redact("Private_Key=supersecretvalue").redactedText == "Private_Key=[REDACTED]")
        #expect(redactor.redact("password_key=12345678").redactedText == "password_key=[REDACTED]")
        #expect(
            redactor.redact(#"{"private_key": "correct horse's battery"}"#).redactedText
                == #"{"private_key=[REDACTED]"}"#
        )
        // The existing password assignment still ends on the keyword. The
        // longer `password_key` alternative does not take this one.
        #expect(
            redactor.redact(#"{"password": "correct horse's battery"}"#).redactedText
                == #"{"password=[REDACTED]"}"#
        )

        let kept = [
            "private_key=1234567",
            "private_keys=supersecretvalue",
            "password_keys=supersecretvalue",
            "password_keyboard=supersecretvalue",
            "PRIVATE_KEY_ID=supersecretvalue",
            "token_key=supersecretvalue",
            "private=supersecretvalue",
        ]
        for line in kept {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line)")
            #expect(result.redactedText == line)
        }

        let key = "xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let labeled = redactor.redact(#"{"private_key": "\#(key)"}"#)
        #expect(labeled.redactedText == #"{"private_key": "xai-[REDACTED]"}"#)
        #expect(labeled.redactionCount == 1)
        #expect(!labeled.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let labeledAgain = redactor.redact(labeled.redactedText)
        #expect(labeledAgain.redactedText == labeled.redactedText)
        #expect(labeledAgain.redactionCount == 0)

        // The PEM pattern runs first. `private_key` must not take a second
        // count off `[REDACTED PRIVATE KEY]`, and the key body stays gone.
        let pem = """
        PRIVATE_KEY=-----BEGIN OPENSSH PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSj
        -----END OPENSSH PRIVATE KEY-----
        """
        let pemResult = redactor.redact(pem)
        #expect(pemResult.redactedText == "PRIVATE_KEY=[REDACTED PRIVATE KEY]")
        #expect(pemResult.redactionCount == 1)
        #expect(!pemResult.redactedText.contains("MIIEv"))
        let pemAgain = redactor.redact(pemResult.redactedText)
        #expect(pemAgain.redactedText == pemResult.redactedText)
        #expect(pemAgain.redactionCount == 0)

        let block = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSj
        -----END RSA PRIVATE KEY-----
        """
        let blockResult = redactor.redact(block)
        #expect(blockResult.redactedText == "[REDACTED PRIVATE KEY]")
        #expect(blockResult.redactionCount == 1)
        #expect(!blockResult.redactedText.contains("MIIEv"))
    }

    @Test("Redacts camelCase secretKey, SecretAccessKey, privateKey, and passwordKey")
    func redactsCamelCaseSecretNames() {
        let redactor = SecretRedactor()
        // The shape `aws sts assume-role` prints. The access key id is not
        // this name. The secret and the session token are.
        let cli = """
        {
            "Credentials": {
                "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
                "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                "SessionToken": "IQoJb3JpZ2luX2VjEXampleTokenValue"
            }
        }
        """
        let cliResult = redactor.redact(cli)
        #expect(
            cliResult.redactedText
                == """
                {
                    "Credentials": {
                        "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
                        "SecretAccessKey=[REDACTED]",
                        "SessionToken=[REDACTED]"
                    }
                }
                """
        )
        #expect(cliResult.redactionCount == 2)
        #expect(!cliResult.redactedText.contains("wJalrXUtnFEMI"))
        #expect(!cliResult.redactedText.contains("IQoJb3JpZ2luX2VjE"))
        #expect(cliResult.redactedText.contains("ASIAIOSFODNN7EXAMPLE"))
        let cliAgain = redactor.redact(cliResult.redactedText)
        #expect(cliAgain.redactedText == cliResult.redactedText)
        #expect(cliAgain.redactionCount == 0)

        let js = redactor.redact(
            #"{"secretKey": "supersecretvalue", "privateKey": "anothersecretvalue", "passwordKey": "thirdsecretvalue"}"#
        )
        #expect(
            js.redactedText
                == #"{"secretKey=[REDACTED]", "privateKey=[REDACTED]", "passwordKey=[REDACTED]"}"#
        )
        #expect(js.redactionCount == 3)
        #expect(!js.redactedText.contains("supersecretvalue"))
        #expect(!js.redactedText.contains("anothersecretvalue"))
        #expect(!js.redactedText.contains("thirdsecretvalue"))
        let jsAgain = redactor.redact(js.redactedText)
        #expect(jsAgain.redactedText == js.redactedText)
        #expect(jsAgain.redactionCount == 0)

        // No separator at all is the same name. A prefix stays on the label,
        // and the captured name keeps its case.
        #expect(
            redactor.redact(
                "secretkey=supersecretvalue SECRETACCESSKEY=anothersecretvalue awsSecretAccessKey=thirdsecretvalue"
            ).redactedText
                == "secretkey=[REDACTED] SECRETACCESSKEY=[REDACTED] awsSecretAccessKey=[REDACTED]"
        )
        #expect(
            redactor.redact("privateKey=supersecretvalue passwordkey=anothersecretvalue").redactedText
                == "privateKey=[REDACTED] passwordkey=[REDACTED]"
        )
        #expect(
            redactor.redact(#"{"secretKey": "correct horse's battery"}"#).redactedText
                == #"{"secretKey=[REDACTED]"}"#
        )
        #expect(redactor.redact("secretKey=12345678").redactedText == "secretKey=[REDACTED]")

        // The name still has to end on the keyword. A plural, a longer
        // identifier, and a 7-character value stay.
        let kept = [
            "secretKeys=supersecretvalue",
            "secretAccessKeyId=supersecretvalue",
            "privateKeys=supersecretvalue",
            "passwordKeyboard=supersecretvalue",
            "passwordKeyId=supersecretvalue",
            "privateKeyId=supersecretvalue",
            "secretKey=1234567",
            "secretary=supersecretvalue",
            "private=supersecretvalue",
        ]
        for line in kept {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line)")
            #expect(result.redactedText == line)
        }

        let key = "xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let labeled = redactor.redact(#"{"secretKey": "\#(key)"}"#)
        #expect(labeled.redactedText == #"{"secretKey": "xai-[REDACTED]"}"#)
        #expect(labeled.redactionCount == 1)
        #expect(!labeled.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let labeledAgain = redactor.redact(labeled.redactedText)
        #expect(labeledAgain.redactedText == labeled.redactedText)
        #expect(labeledAgain.redactionCount == 0)

        // A username that is this keyword keeps the host. `=` is still
        // an assignment, so that host goes with the secret.
        let url = redactor.redact("https://secretKey:supersecret@github.com/org/repo")
        #expect(url.redactedText == "https://secretKey:[REDACTED]@github.com/org/repo")
        #expect(url.redactionCount == 1)
        #expect(!url.redactedText.contains("supersecret"))
        let urlAgain = redactor.redact(url.redactedText)
        #expect(urlAgain.redactedText == url.redactedText)
        #expect(urlAgain.redactionCount == 0)
        let prefixed = redactor.redact("https://my-secretKey:supersecret@github.com/org/repo")
        #expect(prefixed.redactedText == "https://my-secretKey:[REDACTED]@github.com/org/repo")
        #expect(prefixed.redactionCount == 1)
        let equals = redactor.redact("https://secretKey=supersecret@host")
        #expect(equals.redactedText == "https://secretKey=[REDACTED]")
        #expect(!equals.redactedText.contains("supersecret"))
        #expect(!equals.redactedText.contains("@host"))

        let pem = """
        privateKey=-----BEGIN OPENSSH PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSj
        -----END OPENSSH PRIVATE KEY-----
        """
        let pemResult = redactor.redact(pem)
        #expect(pemResult.redactedText == "privateKey=[REDACTED PRIVATE KEY]")
        #expect(pemResult.redactionCount == 1)
        #expect(!pemResult.redactedText.contains("MIIEv"))
        let pemAgain = redactor.redact(pemResult.redactedText)
        #expect(pemAgain.redactedText == pemResult.redactedText)
        #expect(pemAgain.redactionCount == 0)
    }

    @Test("Redacts a Google API key and an OAuth client secret")
    func redactsGoogleAPIKeysAndOAuthClientSecrets() {
        let redactor = SecretRedactor()
        let apiBody = "SyAb-0123456789_cdefghijklmnopqrstu"
        #expect(apiBody.count == 35)
        let apiKey = "AIza" + apiBody
        let oauthBody = "4uHg-MPm_1o7SkgeV6Cu5clXFsxl"
        #expect(oauthBody.count == 28)
        let oauth = "GOCSPX-" + oauthBody

        let maps = redactor.redact(
            "https://maps.googleapis.com/maps/api/js?key=\(apiKey)&libraries=places"
        )
        #expect(
            maps.redactedText
                == "https://maps.googleapis.com/maps/api/js?key=AIza[REDACTED]&libraries=places"
        )
        #expect(maps.redactionCount == 1)
        #expect(!maps.redactedText.contains(apiBody))
        let mapsAgain = redactor.redact(maps.redactedText)
        #expect(mapsAgain.redactedText == maps.redactedText)
        #expect(mapsAgain.redactionCount == 0)

        let firebase = redactor.redact(#"{"current_key": "\#(apiKey)"}"#)
        #expect(firebase.redactedText == #"{"current_key": "AIza[REDACTED]"}"#)
        #expect(firebase.redactionCount == 1)
        #expect(!firebase.redactedText.contains(apiBody))
        let firebaseAgain = redactor.redact(firebase.redactedText)
        #expect(firebaseAgain.redactedText == firebase.redactedText)
        #expect(firebaseAgain.redactionCount == 0)

        let client = redactor.redact(#"{"client_secret": "\#(oauth)"}"#)
        #expect(client.redactedText == #"{"client_secret": "GOCSPX-[REDACTED]"}"#)
        #expect(client.redactionCount == 1)
        #expect(!client.redactedText.contains(oauthBody))
        let clientAgain = redactor.redact(client.redactedText)
        #expect(clientAgain.redactedText == client.redactedText)
        #expect(clientAgain.redactionCount == 0)

        let pair = redactor.redact("saw \(apiKey) and \(oauth).")
        #expect(pair.redactedText == "saw AIza[REDACTED] and GOCSPX-[REDACTED].")
        #expect(pair.redactionCount == 2)
        let pairAgain = redactor.redact(pair.redactedText)
        #expect(pairAgain.redactedText == pair.redactedText)
        #expect(pairAgain.redactionCount == 0)

        let assigned = redactor.redact("token=\(apiKey)")
        #expect(assigned.redactedText == "token=AIza[REDACTED]")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactedText == assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)

        let jsonKey = redactor.redact(#"{"apiKey": "\#(apiKey)"}"#)
        #expect(jsonKey.redactedText == #"{"apiKey": "AIza[REDACTED]"}"#)
        #expect(jsonKey.redactionCount == 1)

        let url = redactor.redact("https://app:\(apiKey)@example.com/path")
        #expect(url.redactedText == "https://app:AIza[REDACTED]@example.com/path")
        #expect(url.redactionCount == 1)
        #expect(url.redactedText.contains("@example.com/path"))
        let urlAgain = redactor.redact(url.redactedText)
        #expect(urlAgain.redactedText == url.redactedText)
        #expect(urlAgain.redactionCount == 0)

        let oauthURL = redactor.redact("https://user:\(oauth)@accounts.google.com/token")
        #expect(oauthURL.redactedText == "https://user:GOCSPX-[REDACTED]@accounts.google.com/token")
        #expect(oauthURL.redactionCount == 1)

        // `@` is still not the end of an ordinary assignment, so the
        // tail after a recognized key is not published.
        let leftover = redactor.redact("token=\(apiKey)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(apiBody))

        let query = redactor.redact("\(apiKey)?x=1")
        #expect(query.redactedText == "AIza[REDACTED]?x=1")
        #expect(query.redactionCount == 1)

        // A short client secret assigned to that name is still an
        // assignment. A bare short one is not this shape.
        let shortOAuth = "GOCSPX-" + String(repeating: "a", count: 27)
        #expect(shortOAuth.count == 34)
        let shortAssigned = redactor.redact("client_secret=\(shortOAuth)")
        #expect(shortAssigned.redactedText == "client_secret=[REDACTED]")
        #expect(shortAssigned.redactionCount == 1)
        #expect(!shortAssigned.redactedText.contains(shortOAuth))

        let kept = [
            "keys start with AIza and GOCSPX- on Google",
            "AIza" + String(repeating: "a", count: 34),
            "AIza" + String(repeating: "a", count: 36),
            "GOCSPX-" + String(repeating: "a", count: 27),
            "GOCSPX-" + String(repeating: "a", count: 29),
            "aiza" + apiBody,
            "gocspx-" + oauthBody,
            "x" + apiKey,
            "_" + apiKey,
            "x" + oauth,
            "_" + oauth,
            "ya29.a0AfH6SMC-short-access-token",
            "123456789012-abcdefghijklmnopqrstuv.apps.googleusercontent.com",
            "ASIAIOSFODNN7EXAMPLE",
        ]
        for line in kept {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line)")
            #expect(result.redactedText == line)
        }
    }

    @Test("Redacts a URL userinfo password and leaves the host")
    func redactsURLUserinfo() {
        let redactor = SecretRedactor()
        let postgres = redactor.redact(
            "DATABASE_URL=postgres://app:supersecret@db.internal:5432/app"
        )
        #expect(postgres.redactedText == "DATABASE_URL=postgres://app:[REDACTED]@db.internal:5432/app")
        #expect(postgres.redactionCount == 1)
        #expect(!postgres.redactedText.contains("supersecret"))
        let postgresAgain = redactor.redact(postgres.redactedText)
        #expect(postgresAgain.redactedText == postgres.redactedText)
        #expect(postgresAgain.redactionCount == 0)

        let json = redactor.redact(
            #"{"database_url": "postgres://app:supersecret@db.internal:5432/app"}"#
        )
        #expect(
            json.redactedText
                == #"{"database_url": "postgres://app:[REDACTED]@db.internal:5432/app"}"#
        )
        #expect(json.redactionCount == 1)
        let jsonAgain = redactor.redact(json.redactedText)
        #expect(jsonAgain.redactedText == json.redactedText)
        #expect(jsonAgain.redactionCount == 0)

        // Scheme case, an empty Redis user, a colon inside the password,
        // a `+` in the scheme, and a driver prefix before `://`.
        #expect(
            redactor.redact("HTTPS://Git:Supersecret@GitHub.com/org/repo.git").redactedText
                == "HTTPS://Git:[REDACTED]@GitHub.com/org/repo.git"
        )
        #expect(
            redactor.redact("redis://:supersecret@localhost:6379/0").redactedText
                == "redis://:[REDACTED]@localhost:6379/0"
        )
        #expect(
            redactor.redact("postgres://app:sec:retvalue@db.internal/app").redactedText
                == "postgres://app:[REDACTED]@db.internal/app"
        )
        #expect(
            redactor.redact("mongodb+srv://app:supersecret@cluster.example.net/db").redactedText
                == "mongodb+srv://app:[REDACTED]@cluster.example.net/db"
        )
        #expect(
            redactor.redact("jdbc:postgresql://app:supersecret@db.internal:5432/app").redactedText
                == "jdbc:postgresql://app:[REDACTED]@db.internal:5432/app"
        )
        // `%40` is an encoded `@` inside the password. The real delimiter
        // is the later `@`, so the whole password goes.
        #expect(
            redactor.redact("https://app:p%40ssw0rd!!@host/path").redactedText
                == "https://app:[REDACTED]@host/path"
        )

        let both = redactor.redact(
            "postgres://app:supersecret@db/app redis://:anothersecret@localhost:6379"
        )
        #expect(
            both.redactedText
                == "postgres://app:[REDACTED]@db/app redis://:[REDACTED]@localhost:6379"
        )
        #expect(both.redactionCount == 2)
        let bothAgain = redactor.redact(both.redactedText)
        #expect(bothAgain.redactionCount == 0)

        // A recognized token keeps its label and the host. The URL pattern
        // does not take a second count off the placeholder.
        let key = "xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let labeled = redactor.redact("postgres://app:\(key)@db.internal/app")
        #expect(labeled.redactedText == "postgres://app:xai-[REDACTED]@db.internal/app")
        #expect(labeled.redactionCount == 1)
        #expect(!labeled.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let labeledAgain = redactor.redact(labeled.redactedText)
        #expect(labeledAgain.redactedText == labeled.redactedText)
        #expect(labeledAgain.redactionCount == 0)

        let ghp = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let remote = redactor.redact("https://git:\(ghp)@github.com/org/repo.git")
        #expect(remote.redactedText == "https://git:ghp_[REDACTED]@github.com/org/repo.git")
        #expect(remote.redactionCount == 1)
        #expect(!remote.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        // No userinfo, a port, a public git remote, a 7-character password,
        // and a short password beside one that meets the floor.
        let kept = [
            "https://example.com:8080/path?x=1",
            "https://example.com/callback?code=12345678",
            "ssh://git@github.com/org/repo.git",
            "git@github.com:org/repo.git",
            "postgres://app:hunter2@localhost/db",
            "http://localhost:8080",
            "see https://example.com/wiki/User:Supersecret@talk",
        ]
        for line in kept {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line)")
            #expect(result.redactedText == line)
        }
        #expect(
            redactor.redact("https://user:short@host https://user:correcthorse@host").redactedText
                == "https://user:short@host https://user:[REDACTED]@host"
        )

        // An assignment whose value is the whole URL is still one
        // redaction. The URL pattern does not see a password after it.
        let assigned = redactor.redact("password=https://git:supersecret@host/repo")
        #expect(assigned.redactedText == "password=[REDACTED]")
        #expect(assigned.redactionCount == 1)
        #expect(!assigned.redactedText.contains("supersecret"))
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
    }

    @Test("A URL username that is an assignment keyword keeps the host")
    func redactsPasswordWhenUsernameIsAKeyword() {
        let redactor = SecretRedactor()
        let ghp = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let github = redactor.redact("https://x-access-token:\(ghp)@github.com/org/repo.git")
        #expect(github.redactedText == "https://x-access-token:ghp_[REDACTED]@github.com/org/repo.git")
        #expect(github.redactionCount == 1)
        #expect(!github.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let githubAgain = redactor.redact(github.redactedText)
        #expect(githubAgain.redactedText == github.redactedText)
        #expect(githubAgain.redactionCount == 0)

        let gitlab = redactor.redact(
            "https://gitlab-ci-token:supersecret@gitlab.com/group/repo.git"
        )
        #expect(gitlab.redactedText == "https://gitlab-ci-token:[REDACTED]@gitlab.com/group/repo.git")
        #expect(gitlab.redactionCount == 1)
        #expect(!gitlab.redactedText.contains("supersecret"))
        let gitlabAgain = redactor.redact(gitlab.redactedText)
        #expect(gitlabAgain.redactionCount == 0)

        let json = redactor.redact(
            #"{"remote": "https://x-access-token:supersecret@github.com/org/repo.git"}"#
        )
        #expect(
            json.redactedText
                == #"{"remote": "https://x-access-token:[REDACTED]@github.com/org/repo.git"}"#
        )
        #expect(json.redactionCount == 1)

        #expect(
            redactor.redact("HTTPS://X-Access-Token:Supersecret@GitHub.com/org/repo.git").redactedText
                == "HTTPS://X-Access-Token:[REDACTED]@GitHub.com/org/repo.git"
        )
        #expect(
            redactor.redact("https://api_key:supersecret@example.com/v1").redactedText
                == "https://api_key:[REDACTED]@example.com/v1"
        )
        #expect(
            redactor.redact("https://client-secret:supersecret@login.example/oauth").redactedText
                == "https://client-secret:[REDACTED]@login.example/oauth"
        )
        #expect(
            redactor.redact("mongodb+srv://password:supersecret@cluster.example.net/db").redactedText
                == "mongodb+srv://password:[REDACTED]@cluster.example.net/db"
        )
        #expect(
            redactor.redact(
                "https://x-access-token:supersecret@github.com/org/repo.git token=anothersecret"
            ).redactedText
                == "https://x-access-token:[REDACTED]@github.com/org/repo.git token=[REDACTED]"
        )

        // 30 characters before `token` is inside the 39-character guard.
        let nearUser = String(repeating: "a", count: 30) + "token"
        let near = redactor.redact("https://\(nearUser):supersecret@host/repo")
        #expect(near.redactedText == "https://\(nearUser):[REDACTED]@host/repo")
        #expect(near.redactionCount == 1)

        // A colon after a path is not a username. The slash keeps the
        // guard from seeing `://` immediately before the keyword, so the
        // assignment still takes the value.
        let path = redactor.redact("https://example.com/callback?token:supersecret@notahost")
        #expect(path.redactedText == "https://example.com/callback?token=[REDACTED]")
        #expect(path.redactionCount == 1)
        #expect(!path.redactedText.contains("supersecret"))
        #expect(!path.redactedText.contains("notahost"))

        // `=` is not userinfo. The secret goes, and so does the host.
        let equals = redactor.redact("https://x-access-token=supersecret@host")
        #expect(equals.redactedText == "https://x-access-token=[REDACTED]")
        #expect(!equals.redactedText.contains("supersecret"))
        #expect(!equals.redactedText.contains("host"))

        // Shorter than 8, or a raw `@` in the password: the URL pattern
        // would leave a piece of it, so the assignment still takes the tail.
        let short = redactor.redact("https://token:hunter2@localhost/db")
        #expect(short.redactedText == "https://token=[REDACTED]")
        #expect(!short.redactedText.contains("hunter2"))
        let rawAt = redactor.redact("https://token:p@ssw0rd!!@host")
        #expect(rawAt.redactedText == "https://token=[REDACTED]")
        #expect(!rawAt.redactedText.contains("ssw0rd"))

        // A recognized token that continues after `@` is not a URL username.
        // The tail is still a secret.
        let key = "xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let leftover = redactor.redact("token=\(key)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))

        // The keyword starts 40 characters after `://`, past the guard.
        // The secret is still not published.
        let farUser = String(repeating: "b", count: 40) + "token"
        let far = redactor.redact("https://\(farUser):supersecret@host/repo")
        #expect(far.redactedText == "https://\(farUser)=[REDACTED]")
        #expect(far.redactionCount == 1)
        #expect(!far.redactedText.contains("supersecret"))
        #expect(!far.redactedText.contains("host/repo"))
    }

    @Test("A bare GitLab token is redacted once and keeps its prefix")
    func redactsGitLabTokens() {
        let redactor = SecretRedactor()
        let body = "abcdefghij" + "klmnopqrstuvwx"
        let shortBody = "abcdefghij" + "klmnopqrs"
        func token(_ prefix: String) -> String { prefix + body }

        let pat = token("gl" + "pat-")
        let bare = redactor.redact("cloned with \(pat)")
        #expect(bare.redactedText == "cloned with glpat-[REDACTED]")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(body))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        // The assignment and the JSON key already name `token`. The
        // prefix stays, and the placeholder is not a second secret.
        let assigned = redactor.redact("GITLAB_TOKEN=\(pat)")
        #expect(assigned.redactedText == "GITLAB_TOKEN=glpat-[REDACTED]")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"token": "\#(pat)"}"#)
        #expect(quoted.redactedText == #"{"token": "glpat-[REDACTED]"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        // The user and the host stay. The CI username ends in `token`,
        // which is an assignment keyword; the host still stays.
        let remote = redactor.redact("https://oauth2:\(pat)@gitlab.com/group/repo.git")
        #expect(remote.redactedText == "https://oauth2:glpat-[REDACTED]@gitlab.com/group/repo.git")
        #expect(remote.redactionCount == 1)
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)
        let job = token("gl" + "cbt-")
        let ci = redactor.redact("https://gitlab-ci-token:\(job)@gitlab.com/group/repo.git")
        #expect(ci.redactedText == "https://gitlab-ci-token:glcbt-[REDACTED]@gitlab.com/group/repo.git")
        #expect(ci.redactionCount == 1)
        #expect(ci.redactedText.contains("gitlab.com/group/repo.git"))

        let prefixes = [
            "gldt-", "glrtr-", "glrt-", "glptt-", "gloas-", "glagent-",
            "glsoat-", "glffct-", "glimt-", "glft-", "gltok-"
        ]
        let line = prefixes.map { token($0) }.joined(separator: " ")
        let many = redactor.redact(line)
        #expect(many.redactionCount == prefixes.count)
        #expect(many.redactedText == prefixes.map { $0 + "[REDACTED]" }.joined(separator: " "))
        #expect(!many.redactedText.contains(body))
        let manyAgain = redactor.redact(many.redactedText)
        #expect(manyAgain.redactedText == many.redactedText)
        #expect(manyAgain.redactionCount == 0)

        // `glrtr-` is the registration token, not `glrt-` plus a leftover.
        let registration = token("gl" + "rtr-")
        let runner = redactor.redact(registration)
        #expect(runner.redactedText == "glrtr-[REDACTED]")
        #expect(runner.redactionCount == 1)
        #expect(!runner.redactedText.contains(body))

        let short = ("gl" + "pat-") + shortBody
        let keptShort = redactor.redact("prefix \(short) stays")
        #expect(keptShort.redactedText == "prefix \(short) stays")
        #expect(keptShort.redactionCount == 0)

        let mention = redactor.redact("tokens start with glpat- on GitLab")
        #expect(mention.redactedText == "tokens start with glpat- on GitLab")
        #expect(mention.redactionCount == 0)

        // A period ends the token. The sentence keeps it.
        let sentence = redactor.redact("saw \(pat). next")
        #expect(sentence.redactedText == "saw glpat-[REDACTED]. next")
        #expect(sentence.redactionCount == 1)
    }

    @Test("A Slack webhook URL is redacted once and keeps its host")
    func redactsSlackWebhookURLs() {
        let redactor = SecretRedactor()
        let secret = "7IsoQTrixdUtE971O1xQTm4T"
        let incoming = "https://hooks.slack.com/services/T0123456789/B1001010101/\(secret)"
        let kept = "https://hooks.slack.com/[REDACTED]"

        let bare = redactor.redact("posted \(incoming)")
        #expect(bare.redactedText == "posted \(kept)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(secret))
        #expect(!bare.redactedText.contains("T0123456789"))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        // The variable is not an assignment keyword. The host still stays,
        // and a second pass does not count the placeholder.
        let env = redactor.redact("SLACK_WEBHOOK_URL=\(incoming)")
        #expect(env.redactedText == "SLACK_WEBHOOK_URL=\(kept)")
        #expect(env.redactionCount == 1)
        let envAgain = redactor.redact(env.redactedText)
        #expect(envAgain.redactionCount == 0)

        // `token=` is an assignment. The placeholder is the whole value,
        // so the host is not consumed and the secret is counted once.
        let assigned = redactor.redact("token=\(incoming)")
        #expect(assigned.redactedText == "token=\(kept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"url": "\#(incoming)"}"#)
        #expect(quoted.redactedText == #"{"url": "\#(kept)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let triggerSecret = "c6e6c0d868b3054ca0f4611a5dbadaf"
        let trigger = "https://hooks.slack.com/triggers/T0123456789/3141592653589/\(triggerSecret)"
        let triggered = redactor.redact(trigger)
        #expect(triggered.redactedText == kept)
        #expect(triggered.redactionCount == 1)
        #expect(!triggered.redactedText.contains(triggerSecret))

        let workflowA = "abcdefghijklmnopqrstuvwxyz012345"
        let workflowB = "zyxwvutsrqponmlkjihgfedcba654321"
        let workflow = "https://hooks.slack.com/workflows/T0123456789/F0123456789/\(workflowA)/\(workflowB)"
        let flowed = redactor.redact(workflow)
        #expect(flowed.redactedText == kept)
        #expect(flowed.redactionCount == 1)
        #expect(!flowed.redactedText.contains(workflowA))
        #expect(!flowed.redactedText.contains(workflowB))

        let govSecret = "GovSlackSecretValue99"
        let gov = "https://hooks.slack-gov.com/services/T0123456789/B1001010101/\(govSecret)"
        let govResult = redactor.redact(gov)
        #expect(govResult.redactedText == "https://hooks.slack-gov.com/[REDACTED]")
        #expect(govResult.redactionCount == 1)
        #expect(!govResult.redactedText.contains(govSecret))
        let govAgain = redactor.redact(govResult.redactedText)
        #expect(govAgain.redactionCount == 0)

        let http = redactor.redact(
            "http://hooks.slack.com/services/T0123456789/B1001010101/\(secret)"
        )
        #expect(http.redactedText == kept)
        #expect(http.redactionCount == 1)
        let upper = redactor.redact(
            "HTTPS://HOOKS.SLACK.COM/SERVICES/T0123456789/B1001010101/\(secret)"
        )
        #expect(upper.redactedText == kept)
        #expect(upper.redactionCount == 1)
        let bareHost = redactor.redact(
            "hooks.slack.com/services/T0123456789/B1001010101/\(secret)"
        )
        #expect(bareHost.redactedText == kept)
        #expect(bareHost.redactionCount == 1)

        let pair = redactor.redact("\(incoming) \(trigger)")
        #expect(pair.redactedText == "\(kept) \(kept)")
        #expect(pair.redactionCount == 2)
        let pairAgain = redactor.redact(pair.redactedText)
        #expect(pairAgain.redactionCount == 0)

        let sentence = redactor.redact("posted \(incoming). next")
        #expect(sentence.redactedText == "posted \(kept). next")
        #expect(sentence.redactionCount == 1)
        let query = redactor.redact(incoming + "?x=1")
        #expect(query.redactedText == kept + "?x=1")
        #expect(query.redactionCount == 1)
        #expect(!query.redactedText.contains(secret))

        let docs = redactor.redact("see https://hooks.slack.com/services for setup")
        #expect(docs.redactedText == "see https://hooks.slack.com/services for setup")
        #expect(docs.redactionCount == 0)
        let short = "https://hooks.slack.com/services/T0123456789/B0123456789/abcdefghijklmno"
        let keptShort = redactor.redact(short)
        #expect(keptShort.redactedText == short)
        #expect(keptShort.redactionCount == 0)
        let team = "https://hooks.slack.com/services/T123456/B0123456789/" + String(repeating: "a", count: 24)
        let keptTeam = redactor.redact(team)
        #expect(keptTeam.redactedText == team)
        #expect(keptTeam.redactionCount == 0)
        let glued = "myhooks.slack.com/services/T0123456789/B1001010101/\(secret)"
        let keptGlued = redactor.redact(glued)
        #expect(keptGlued.redactedText == glued)
        #expect(keptGlued.redactionCount == 0)
        let evil = "https://hooks.slack.com.evil.com/services/T0123456789/B1001010101/\(secret)"
        let keptEvil = redactor.redact(evil)
        #expect(keptEvil.redactedText == evil)
        #expect(keptEvil.redactionCount == 0)
    }

    @Test("Slack app, rotation, and client tokens are redacted once")
    func redactsSlackAppRotationAndClientTokens() {
        let redactor = SecretRedactor()
        let app = "xapp" + "-1-A0123456789-1234567890123-" + String(repeating: "ab", count: 32)
        let appSecret = String(repeating: "ab", count: 32)

        let bare = redactor.redact("socket \(app)")
        #expect(bare.redactedText == "socket xapp-[REDACTED]")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(appSecret))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        // The variable ends in `token`, which is an assignment keyword.
        // The label stays, and the placeholder is not a second secret.
        let assigned = redactor.redact("token=\(app)")
        #expect(assigned.redactedText == "token=xapp-[REDACTED]")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let env = redactor.redact("SLACK_APP_TOKEN=\(app)")
        #expect(env.redactedText == "SLACK_APP_TOKEN=xapp-[REDACTED]")
        #expect(env.redactionCount == 1)
        let quoted = redactor.redact(#"{"token": "\#(app)"}"#)
        #expect(quoted.redactedText == #"{"token": "xapp-[REDACTED]"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let upper = redactor.redact(app.uppercased())
        #expect(upper.redactedText == "xapp-[REDACTED]")
        #expect(upper.redactionCount == 1)
        let glued = redactor.redact("n" + app)
        #expect(glued.redactedText == "n" + app)
        #expect(glued.redactionCount == 0)
        let underscored = redactor.redact("_" + app)
        #expect(underscored.redactedText == "_" + app)
        #expect(underscored.redactionCount == 0)

        let shortApp = "xapp" + "-1-A012345678-12345678-" + String(repeating: "a", count: 31)
        let keptShort = redactor.redact(shortApp)
        #expect(keptShort.redactedText == shortApp)
        #expect(keptShort.redactionCount == 0)
        let floorApp = "xapp" + "-1-A012345678-12345678-" + String(repeating: "b", count: 32)
        #expect(redactor.redact(floorApp).redactedText == "xapp-[REDACTED]")

        let mention = redactor.redact("tokens start with xapp- and xoxc- on Slack")
        #expect(mention.redactedText == "tokens start with xapp- and xoxc- on Slack")
        #expect(mention.redactionCount == 0)

        // `+` after 20 alphabet characters is where `xox[baprs]` stops.
        // The tail would stay. The rotation pattern takes the whole token.
        let lateBody = "xoxe.xox" + "p-1-" + String(repeating: "A", count: 20) + "+c/dEf=Tail"
        let late = lateBody + "."
        let lateResult = redactor.redact(late)
        #expect(lateResult.redactedText == "xoxe.xox[REDACTED].")
        #expect(lateResult.redactionCount == 1)
        #expect(!lateResult.redactedText.contains("Tail"))
        #expect(!lateResult.redactedText.contains("+"))
        let lateAgain = redactor.redact(lateResult.redactedText)
        #expect(lateAgain.redactionCount == 0)
        // The period is not a placeholder boundary, so the assignment
        // case is the token without it. The label stays, and it counts once.
        let lateAssigned = redactor.redact("token=\(lateBody)")
        #expect(lateAssigned.redactedText == "token=xoxe.xox[REDACTED]")
        #expect(lateAssigned.redactionCount == 1)

        // `+` inside the first 10 characters: the older pattern matches
        // nothing, so the whole secret would remain.
        let early = "xoxe.xox" + "p-1-Mi0yAb+" + "c/dEf=" + String(repeating: "Qw", count: 30)
        let earlyResult = redactor.redact(early)
        #expect(earlyResult.redactedText == "xoxe.xox[REDACTED]")
        #expect(earlyResult.redactionCount == 1)
        #expect(!earlyResult.redactedText.contains("Mi0yAb"))
        #expect(!earlyResult.redactedText.contains("Qw"))

        let alnum = "xoxe.xox" + "b-1-" + String(repeating: "A", count: 40)
        let alnumResult = redactor.redact(alnum)
        #expect(alnumResult.redactedText == "xoxe.xox[REDACTED]")
        #expect(alnumResult.redactionCount == 1)
        let alnumAgain = redactor.redact(alnumResult.redactedText)
        #expect(alnumAgain.redactionCount == 0)
        let accessUpper = ("xoxe.xox" + "p-1-" + String(repeating: "ab", count: 20)).uppercased()
        #expect(redactor.redact(accessUpper).redactedText == "xoxe.xox[REDACTED]")

        let refresh = "xoxe" + "-1-" + "My0xAb+" + "c/dEf=" + String(repeating: "rm", count: 20)
        let refreshResult = redactor.redact(refresh)
        #expect(refreshResult.redactedText == "xoxe-[REDACTED]")
        #expect(refreshResult.redactionCount == 1)
        #expect(!refreshResult.redactedText.contains("c/dEf"))
        #expect(!refreshResult.redactedText.contains("rmrm"))
        let refreshAgain = redactor.redact(refreshResult.redactedText)
        #expect(refreshAgain.redactionCount == 0)
        let refreshAssigned = redactor.redact("token=\(refresh)")
        #expect(refreshAssigned.redactedText == "token=xoxe-[REDACTED]")
        #expect(refreshAssigned.redactionCount == 1)

        let fileTok = "xoxe" + "-" + "1111111111111-2222222222222-3333333333333-" + String(repeating: "ab", count: 16)
        let file = redactor.redact("https://files.slack.com/files-pri/T04/image.png?t=\(fileTok)")
        #expect(file.redactedText == "https://files.slack.com/files-pri/T04/image.png?t=xoxe-[REDACTED]")
        #expect(file.redactionCount == 1)
        #expect(!file.redactedText.contains("1111111111111"))

        let pair = redactor.redact("\(late) \(refresh)")
        #expect(pair.redactedText == "xoxe.xox[REDACTED]. xoxe-[REDACTED]")
        #expect(pair.redactionCount == 2)

        let client = "xox" + "c-123456789012-123456789012-" + String(repeating: "ab", count: 16)
        let clientResult = redactor.redact("saw \(client). next")
        #expect(clientResult.redactedText == "saw xoxc-[REDACTED]. next")
        #expect(clientResult.redactionCount == 1)
        #expect(!clientResult.redactedText.contains("123456789012"))
        let clientAgain = redactor.redact(clientResult.redactedText)
        #expect(clientAgain.redactionCount == 0)

        let shortRefresh = "xoxe" + "-1-" + String(repeating: "a", count: 10)
        #expect(redactor.redact(shortRefresh).redactedText == shortRefresh)
        let shortAccess = "xoxe.xox" + "p-1-abc+defghij"
        #expect(redactor.redact(shortAccess).redactedText == shortAccess)
        let shortClient = "xox" + "c-" + String(repeating: "a", count: 23)
        #expect(redactor.redact(shortClient).redactedText == shortClient)
        let clientFloor = "xox" + "c-" + String(repeating: "a", count: 24)
        #expect(redactor.redact(clientFloor).redactedText == "xoxc-[REDACTED]")

        // A classic bot token still uses the older label.
        let bot = "xox" + "b-" + "123456789012-" + "abcdefghijklmnopqrstuvwx"
        let botResult = redactor.redact(bot)
        #expect(botResult.redactedText == "xox[REDACTED]")
        #expect(botResult.redactionCount == 1)

        let cookie = "xox" + "d-" + String(repeating: "a", count: 40)
        #expect(redactor.redact(cookie).redactedText == cookie)
        let workflow = "xwfp-" + String(repeating: "a", count: 40)
        #expect(redactor.redact(workflow).redactedText == workflow)
        let legacy = "xox" + "o-" + String(repeating: "a", count: 40)
        #expect(redactor.redact(legacy).redactedText == legacy)
    }

    @Test("Discord and Teams webhook URLs are redacted once and keep a host")
    func redactsDiscordAndTeamsWebhookURLs() {
        let redactor = SecretRedactor()
        let id = String(repeating: "1", count: 17)
        let id18 = String(repeating: "1", count: 18)
        let id20 = String(repeating: "2", count: 20)
        let id16 = String(repeating: "1", count: 16)
        let id21 = String(repeating: "3", count: 21)
        let token = String(repeating: "c", count: 68)
        let token20 = String(repeating: "a", count: 20)
        let token19 = String(repeating: "b", count: 19)
        let discordKept = "https://discord.com/api/webhooks/[REDACTED]"
        let hook = "https://discord.com/api/webhooks/\(id)/\(token)"

        let bare = redactor.redact("posted \(hook)")
        #expect(bare.redactedText == "posted \(discordKept)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(token))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        let env = redactor.redact("DISCORD_WEBHOOK_URL=\(hook)")
        #expect(env.redactedText == "DISCORD_WEBHOOK_URL=\(discordKept)")
        #expect(env.redactionCount == 1)
        let envAgain = redactor.redact(env.redactedText)
        #expect(envAgain.redactionCount == 0)
        let assigned = redactor.redact("token=\(hook)")
        #expect(assigned.redactedText == "token=\(discordKept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"url": "\#(hook)"}"#)
        #expect(quoted.redactedText == #"{"url": "\#(discordKept)"}"#)
        #expect(quoted.redactionCount == 1)

        let samples = [
            "https://canary.discord.com/api/webhooks/\(id)/\(token20)",
            "https://ptb.discordapp.com/api/webhooks/\(id20)/\(token20)",
            "https://discordapp.com/api/webhooks/\(id18)/\(token20)_-x",
            "https://discord.com/api/v10/webhooks/\(id)/\(token)",
            "http://discord.com/api/webhooks/\(id)/\(token)",
            "HTTPS://DISCORD.COM/API/WEBHOOKS/\(id)/\(token.uppercased())",
            "discord.com/api/webhooks/\(id)/\(token)",
        ]
        for sample in samples {
            let result = redactor.redact(sample)
            #expect(result.redactedText == discordKept)
            #expect(result.redactionCount == 1)
        }
        #expect(!redactor.redact(samples[2]).redactedText.contains("_-x"))

        let pair = redactor.redact("\(hook) \(hook)")
        #expect(pair.redactedText == "\(discordKept) \(discordKept)")
        #expect(pair.redactionCount == 2)
        let sentence = redactor.redact("posted \(hook). next")
        #expect(sentence.redactedText == "posted \(discordKept). next")
        #expect(sentence.redactionCount == 1)
        let query = redactor.redact(hook + "?wait=true")
        #expect(query.redactedText == discordKept + "?wait=true")
        #expect(query.redactionCount == 1)
        #expect(!query.redactedText.contains(token))
        let slash = redactor.redact(hook + "/")
        #expect(slash.redactedText == discordKept + "/")

        let idTooShort = "https://discord.com/api/webhooks/\(id16)/\(token)"
        #expect(redactor.redact(idTooShort).redactedText == idTooShort)
        let idTooLong = "https://discord.com/api/webhooks/\(id21)/\(token)"
        #expect(redactor.redact(idTooLong).redactedText == idTooLong)
        let tokenTooShort = "https://discord.com/api/webhooks/\(id)/\(token19)"
        #expect(redactor.redact(tokenTooShort).redactedText == tokenTooShort)
        let docs = redactor.redact("see https://discord.com/api/webhooks for setup")
        #expect(docs.redactedText == "see https://discord.com/api/webhooks for setup")
        #expect(docs.redactionCount == 0)
        let glued = "mydiscord.com/api/webhooks/\(id)/\(token)"
        #expect(redactor.redact(glued).redactedText == glued)
        let evil = "https://discord.com.evil.com/api/webhooks/\(id)/\(token)"
        #expect(redactor.redact(evil).redactedText == evil)

        let group = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let tenant = "11111111-2222-4333-8444-555555555555"
        let alternate = String(repeating: "0123456789abcdef", count: 2)
        let owner = "ffffffff-eeee-4ddd-8ccc-bbbbbbbbbbbb"
        let path = "\(group)@\(tenant)/IncomingWebhook/\(alternate)/\(owner)"
        let teamsKept = "https://webhook.office.com/[REDACTED]"
        let teams = "https://contoso.webhook.office.com/webhookb2/\(path)"

        let teamsResult = redactor.redact(teams)
        #expect(teamsResult.redactedText == teamsKept)
        #expect(teamsResult.redactionCount == 1)
        #expect(!teamsResult.redactedText.contains(alternate))
        #expect(!teamsResult.redactedText.contains("contoso"))
        let teamsAgain = redactor.redact(teamsResult.redactedText)
        #expect(teamsAgain.redactionCount == 0)

        let hyphen = redactor.redact("https://contoso-corp.webhook.office.com/webhookb2/\(path)")
        #expect(hyphen.redactedText == teamsKept)
        #expect(hyphen.redactionCount == 1)
        let withoutB2 = redactor.redact("https://contoso.webhook.office.com/webhook/\(path)")
        #expect(withoutB2.redactedText == teamsKept)
        let teamsEnv = redactor.redact("TEAMS_WEBHOOK_URL=\(teams)")
        #expect(teamsEnv.redactedText == "TEAMS_WEBHOOK_URL=\(teamsKept)")
        #expect(teamsEnv.redactionCount == 1)
        let teamsAssigned = redactor.redact("token=\(teams)")
        #expect(teamsAssigned.redactedText == "token=\(teamsKept)")
        #expect(teamsAssigned.redactionCount == 1)
        let teamsAssignedAgain = redactor.redact(teamsAssigned.redactedText)
        #expect(teamsAssignedAgain.redactionCount == 0)

        let teamsSamples = [
            "http://contoso.webhook.office.com/webhookb2/\(path)",
            "HTTPS://CONTOSO.WEBHOOK.OFFICE.COM/WEBHOOKB2/\(path.uppercased())",
            "contoso.webhook.office.com/webhookb2/\(path)",
        ]
        for sample in teamsSamples {
            let result = redactor.redact(sample)
            #expect(result.redactedText == teamsKept)
            #expect(result.redactionCount == 1)
        }
        let teamsSentence = redactor.redact("posted \(teams). next")
        #expect(teamsSentence.redactedText == "posted \(teamsKept). next")
        let teamsQuery = redactor.redact(teams + "?x=1")
        #expect(teamsQuery.redactedText == teamsKept + "?x=1")
        #expect(teamsQuery.redactionCount == 1)
        #expect(!teamsQuery.redactedText.contains(alternate))

        let teamsDocs = "see https://contoso.webhook.office.com/webhookb2 for setup"
        #expect(redactor.redact(teamsDocs).redactedText == teamsDocs)
        let teamsEvil = "https://contoso.webhook.office.com.evil.com/webhookb2/\(path)"
        #expect(redactor.redact(teamsEvil).redactedText == teamsEvil)
        let noTenant = "https://webhook.office.com/webhookb2/\(path)"
        #expect(redactor.redact(noTenant).redactedText == noTenant)
        let shortAlt = "https://contoso.webhook.office.com/webhookb2/\(group)@\(tenant)/IncomingWebhook/\(String(repeating: "ab", count: 15))/\(owner)"
        #expect(redactor.redact(shortAlt).redactedText == shortAlt)

        let legacyOffice = redactor.redact("https://outlook.office.com/webhook/\(path)")
        #expect(legacyOffice.redactedText == "https://outlook.office.com/[REDACTED]")
        #expect(legacyOffice.redactionCount == 1)
        #expect(!legacyOffice.redactedText.contains(alternate))
        let legacyAgain = redactor.redact(legacyOffice.redactedText)
        #expect(legacyAgain.redactionCount == 0)
        let legacy365 = redactor.redact("https://outlook.office365.com/webhook/\(path)")
        #expect(legacy365.redactedText == "https://outlook.office365.com/[REDACTED]")
        #expect(legacy365.redactionCount == 1)
        let legacy365Again = redactor.redact(legacy365.redactedText)
        #expect(legacy365Again.redactionCount == 0)

        let sig = String(repeating: "ab", count: 22)
        let logic = "https://prod-12.westus.logic.azure.com:443/workflows/\(group)/triggers/manual/paths/invoke?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=\(sig)"
        let logicKept = "https://logic.azure.com/[REDACTED]"
        let logicResult = redactor.redact(logic)
        #expect(logicResult.redactedText == logicKept)
        #expect(logicResult.redactionCount == 1)
        #expect(!logicResult.redactedText.contains(sig))
        let logicAgain = redactor.redact(logicResult.redactedText)
        #expect(logicAgain.redactionCount == 0)
        let logicAssigned = redactor.redact("token=\(logic)")
        #expect(logicAssigned.redactedText == "token=\(logicKept)")
        #expect(logicAssigned.redactionCount == 1)
        let logicTail = redactor.redact(logic + "&foo=1")
        #expect(logicTail.redactedText == logicKept + "&foo=1")
        #expect(logicTail.redactionCount == 1)
        #expect(!logicTail.redactedText.contains(sig))
        let noPort = logic.replacingOccurrences(of: ":443", with: "")
        #expect(redactor.redact(noPort).redactedText == logicKept)

        let mixedSig = String(repeating: "a+/", count: 10) + "bbbb"
        let named = "https://prod-12.westus.logic.azure.com/workflows/\(group)/triggers/When_a_HTTP_request_is_received/paths/invoke?sig=\(mixedSig)"
        let namedResult = redactor.redact(named)
        #expect(namedResult.redactedText == logicKept)
        #expect(namedResult.redactionCount == 1)
        #expect(!namedResult.redactedText.contains("a+/"))
        #expect(!namedResult.redactedText.contains("bbbb"))

        let shortSig = logic.replacingOccurrences(of: sig, with: String(repeating: "a", count: 19))
        #expect(redactor.redact(shortSig).redactedText == shortSig)
        let logicDocs = "see https://prod-12.westus.logic.azure.com/workflows for setup"
        #expect(redactor.redact(logicDocs).redactedText == logicDocs)
        let logicEvil = logic.replacingOccurrences(of: "logic.azure.com", with: "logic.azure.com.evil.com")
        #expect(redactor.redact(logicEvil).redactedText == logicEvil)
    }

    @Test("Redacts an HTTP Basic credential and leaves the header")
    func redactsAuthorizationBasic() {
        let redactor = SecretRedactor()
        // user:password, user:pass (no digit), app:ab (8, no digit),
        // ab:cd (padding, no lowercase), root:root (one capital, digits).
        let userPassword = "dXNlcjpwYXNzd29yZA=="
        let userPass = "dXNlcjpwYXNz"
        let appAb = "YXBwOmFi"
        let abCd = "YWI6Y2Q="
        let root = "cm9vdDpyb290"

        let header = redactor.redact("Authorization: Basic \(userPassword)")
        #expect(header.redactedText == "Authorization: Basic [REDACTED]")
        #expect(header.redactionCount == 1)
        #expect(!header.redactedText.contains(userPassword))
        let headerAgain = redactor.redact(header.redactedText)
        #expect(headerAgain.redactedText == header.redactedText)
        #expect(headerAgain.redactionCount == 0)

        #expect(redactor.redact("Authorization: Basic \(userPass)").redactedText == "Authorization: Basic [REDACTED]")
        #expect(redactor.redact("authorization: basic \(userPassword)").redactedText == "authorization: basic [REDACTED]")
        #expect(
            redactor.redact("PROXY-AUTHORIZATION: BASIC \(userPassword)").redactedText
                == "PROXY-AUTHORIZATION: BASIC [REDACTED]"
        )
        #expect(
            redactor.redact("Proxy-Authorization: Basic \(userPass)").redactedText
                == "Proxy-Authorization: Basic [REDACTED]"
        )
        // No space between the scheme and the token, and none after the colon.
        #expect(
            redactor.redact("Authorization:Basic\(userPassword)").redactedText
                == "Authorization:Basic[REDACTED]"
        )
        // Padding omitted. `+` and `/` are part of the token.
        #expect(redactor.redact("Authorization: Basic dXNlcjpwYXNzd29yZA").redactedText == "Authorization: Basic [REDACTED]")
        #expect(redactor.redact("Authorization: Basic \(appAb)").redactedText == "Authorization: Basic [REDACTED]")
        #expect(redactor.redact("Authorization: Basic \(abCd)").redactedText == "Authorization: Basic [REDACTED]")
        #expect(redactor.redact("Authorization: Basic YWI6Yw==").redactedText == "Authorization: Basic [REDACTED]")
        #expect(redactor.redact("Authorization: Basic \(root)").redactedText == "Authorization: Basic [REDACTED]")
        #expect(redactor.redact("Authorization: Basic dXNlcjp+fn5+").redactedText == "Authorization: Basic [REDACTED]")
        #expect(redactor.redact("Authorization: Basic YWI6Y2QvZWY=").redactedText == "Authorization: Basic [REDACTED]")

        let json = redactor.redact(
            #"{"Authorization": "Basic \#(userPassword)", "host": "db.internal"}"#
        )
        #expect(
            json.redactedText
                == #"{"Authorization": "Basic [REDACTED]", "host": "db.internal"}"#
        )
        #expect(json.redactionCount == 1)
        #expect(!json.redactedText.contains(userPassword))
        let jsonAgain = redactor.redact(json.redactedText)
        #expect(jsonAgain.redactedText == json.redactedText)
        #expect(jsonAgain.redactionCount == 0)
        #expect(
            redactor.redact("{'Authorization': 'Basic \(userPassword)'}").redactedText
                == "{'Authorization': 'Basic [REDACTED]'}"
        )
        #expect(
            redactor.redact(#"{"authorization":"basic \#(userPassword)"}"#).redactedText
                == #"{"authorization":"basic [REDACTED]"}"#
        )

        let curl = redactor.redact("> Authorization: Basic \(userPassword)\r\nHost: db.internal")
        #expect(curl.redactedText == "> Authorization: Basic [REDACTED]\r\nHost: db.internal")
        #expect(curl.redactionCount == 1)
        let folded = redactor.redact("Authorization:\nBasic \(userPassword)")
        #expect(folded.redactedText == "Authorization:\nBasic [REDACTED]")

        let both = redactor.redact(
            "Authorization: Basic \(userPass) Proxy-Authorization: Basic \(root)"
        )
        #expect(
            both.redactedText
                == "Authorization: Basic [REDACTED] Proxy-Authorization: Basic [REDACTED]"
        )
        #expect(both.redactionCount == 2)
        let bothAgain = redactor.redact(both.redactedText)
        #expect(bothAgain.redactionCount == 0)

        // The period and the following word stay. A tab is still a separator.
        #expect(redactor.redact("Authorization: Basic \(userPass).").redactedText == "Authorization: Basic [REDACTED].")
        #expect(
            redactor.redact("sent Authorization: Basic \(userPassword) to db").redactedText
                == "sent Authorization: Basic [REDACTED] to db"
        )
        #expect(
            redactor.redact("Authorization:\tBasic\t\(userPassword)").redactedText
                == "Authorization:\tBasic\t[REDACTED]"
        )

        // A recognized token keeps its label. Basic does not take a second count.
        let key = "xai-abcdefghijklmnopqrstuvwxyz0123456789"
        let labeled = redactor.redact("Authorization: Basic \(key)")
        #expect(labeled.redactedText == "Authorization: Basic xai-[REDACTED]")
        #expect(labeled.redactionCount == 1)
        #expect(!labeled.redactedText.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let labeledAgain = redactor.redact(labeled.redactedText)
        #expect(labeledAgain.redactedText == labeled.redactedText)
        #expect(labeledAgain.redactionCount == 0)

        let ghp = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let pat = redactor.redact("Authorization: Basic \(ghp)")
        #expect(pat.redactedText == "Authorization: Basic ghp_[REDACTED]")
        #expect(pat.redactionCount == 1)
        let patAgain = redactor.redact(pat.redactedText)
        #expect(patAgain.redactionCount == 0)

        let bearer = "eyJhbGciOiJIUzI1NiJ9.test.sig"
        let mixed = redactor.redact(
            "Authorization: Bearer \(bearer)\nAuthorization: Basic \(userPassword)"
        )
        #expect(
            mixed.redactedText
                == "Authorization: Bearer [REDACTED]\nAuthorization: Basic [REDACTED]"
        )
        #expect(mixed.redactionCount == 2)
        #expect(!mixed.redactedText.contains(bearer))
        #expect(!mixed.redactedText.contains(userPassword))
        let mixedAgain = redactor.redact(mixed.redactedText)
        #expect(mixedAgain.redactionCount == 0)

        // An assignment on the same line is still its own redaction.
        let alongside = redactor.redact(
            "token=supersecretvalue Authorization: Basic \(userPassword)"
        )
        #expect(
            alongside.redactedText
                == "token=[REDACTED] Authorization: Basic [REDACTED]"
        )
        #expect(alongside.redactionCount == 2)
        let alongsideAgain = redactor.redact(alongside.redactedText)
        #expect(alongsideAgain.redactionCount == 0)

        // Two capitals is the base64 signal. One capital, and an
        // all-lowercase word, are not.
        #expect(redactor.redact("Authorization: Basic TestTest").redactedText == "Authorization: Basic [REDACTED]")
        #expect(redactor.redact("Authorization: Basic ABCdefgh").redactedText == "Authorization: Basic [REDACTED]")

        let kept = [
            "Authorization: Basic authentication",
            "Authorization: Basic Authentication",
            "Authorization: Basic password",
            "Authorization: Basic Password",
            "Authorization: Basic hunter2",
            "Authorization: Basic YTph",
            "Authorization: Basic password==",
            "Basic authentication is documented in RFC 7617",
            "See Authorization: Basic in RFC 7617",
            "MyAuthorization: Basic \(userPassword)",
            "Authorization: Basicly \(userPassword)",
            "Authorization: Basic <credentials>",
            "Authorization: Basic password\nNOTE: later",
        ]
        for line in kept {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line)")
            #expect(result.redactedText == line)
        }
    }

    @Test("Stripe restricted keys and webhook secrets are redacted once")
    func redactsStripeRestrictedKeysAndWebhookSecrets() {
        let redactor = SecretRedactor()
        let body = "abcdefghijklmnopqrstuvwxyz0123"
        let live = "rk" + "_live_" + body
        let testKey = "rk" + "_test_" + body
        let keptLive = "rk" + "_live_[REDACTED]"
        let keptTest = "rk" + "_test_[REDACTED]"

        let bare = redactor.redact("charged with \(live)")
        #expect(bare.redactedText == "charged with \(keptLive)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(body))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        let sandbox = redactor.redact("sandbox \(testKey)")
        #expect(sandbox.redactedText == "sandbox \(keptTest)")
        #expect(sandbox.redactionCount == 1)
        let sandboxAgain = redactor.redact(sandbox.redactedText)
        #expect(sandboxAgain.redactionCount == 0)

        let pair = redactor.redact("\(live) \(testKey)")
        #expect(pair.redactedText == "\(keptLive) \(keptTest)")
        #expect(pair.redactionCount == 2)
        let pairAgain = redactor.redact(pair.redactedText)
        #expect(pairAgain.redactionCount == 0)

        // The secret key beside it keeps its own label. Both count.
        let secret = "sk" + "_live_" + body
        let keptSecret = "sk" + "_live_[REDACTED]"
        let beside = redactor.redact("secret=\(secret) restricted=\(live)")
        #expect(beside.redactedText == "secret=\(keptSecret) restricted=\(keptLive)")
        #expect(beside.redactionCount == 2)
        #expect(!beside.redactedText.contains(body))
        let besideAgain = redactor.redact(beside.redactedText)
        #expect(besideAgain.redactionCount == 0)

        let assigned = redactor.redact("token=\(live)")
        #expect(assigned.redactedText == "token=\(keptLive)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"token": "\#(testKey)"}"#)
        #expect(quoted.redactedText == #"{"token": "\#(keptTest)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let remote = redactor.redact("https://app:\(live)@api.stripe.com/v1")
        #expect(remote.redactedText == "https://app:\(keptLive)@api.stripe.com/v1")
        #expect(remote.redactionCount == 1)
        #expect(!remote.redactedText.contains(body))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactedText == remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        let floor = "rk" + "_live_" + String(repeating: "a", count: 20)
        #expect(redactor.redact(floor).redactedText == keptLive)
        let short = "rk" + "_live_" + String(repeating: "a", count: 19)
        #expect(redactor.redact(short).redactedText == short)
        let shortTest = "rk" + "_test_" + String(repeating: "b", count: 19)
        #expect(redactor.redact(shortTest).redactedText == shortTest)

        // The letters occur inside ordinary words. Those words stay.
        let network = "network" + "_live_" + body
        #expect(redactor.redact("mode \(network)").redactedText == "mode \(network)")
        let mark = "mark" + "_test_" + body
        #expect(redactor.redact(mark).redactedText == mark)

        // Publishable keys are not this prefix.
        let publishable = "pk" + "_live_" + body
        let publishableTest = "pk" + "_test_" + body
        #expect(redactor.redact(publishable).redactedText == publishable)
        #expect(redactor.redact(publishableTest).redactedText == publishableTest)
        let ephemeral = "ek" + "_live_" + body
        #expect(redactor.redact(ephemeral).redactedText == ephemeral)

        let upper = "RK" + "_LIVE_" + body
        #expect(redactor.redact(upper).redactedText == upper)
        let glued = "x" + live
        #expect(redactor.redact(glued).redactedText == glued)
        let underscored = "_" + live
        #expect(redactor.redact(underscored).redactedText == underscored)
        let sentence = redactor.redact("used \(live). next")
        #expect(sentence.redactedText == "used \(keptLive). next")
        #expect(sentence.redactionCount == 1)
        // A `+` is not part of the key. The key is gone and the tail stays.
        let plus = redactor.redact(live + "+note")
        #expect(plus.redactedText == keptLive + "+note")
        #expect(plus.redactionCount == 1)
        #expect(!plus.redactedText.contains(body))

        let hookBody = String(repeating: "c", count: 32)
        let hook = "whsec" + "_" + hookBody
        let hookKept = "whsec" + "_[REDACTED]"
        let hookResult = redactor.redact("signing \(hook)")
        #expect(hookResult.redactedText == "signing \(hookKept)")
        #expect(hookResult.redactionCount == 1)
        #expect(!hookResult.redactedText.contains(hookBody))
        let hookAgain = redactor.redact(hookResult.redactedText)
        #expect(hookAgain.redactedText == hookResult.redactedText)
        #expect(hookAgain.redactionCount == 0)

        // Base64 `+`, `/`, and padding are the secret, not a tail.
        let mixed = "whsec" + "_" + "C2FVsBQIhrscChlQIMV" + "+b5sSYspob7oD" + "/w=="
        let mixedResult = redactor.redact(mixed)
        #expect(mixedResult.redactedText == hookKept)
        #expect(mixedResult.redactionCount == 1)
        #expect(!mixedResult.redactedText.contains("+b5s"))
        #expect(!mixedResult.redactedText.contains("/w"))
        #expect(!mixedResult.redactedText.contains("=="))
        let mixedAgain = redactor.redact(mixedResult.redactedText)
        #expect(mixedAgain.redactionCount == 0)

        let hookAssigned = redactor.redact("token=\(hook)")
        #expect(hookAssigned.redactedText == "token=\(hookKept)")
        #expect(hookAssigned.redactionCount == 1)
        let hookAssignedAgain = redactor.redact(hookAssigned.redactedText)
        #expect(hookAssignedAgain.redactionCount == 0)
        let hookJSON = redactor.redact(#"{"secret": "\#(hook)"}"#)
        #expect(hookJSON.redactedText == #"{"secret": "\#(hookKept)"}"#)
        #expect(hookJSON.redactionCount == 1)
        let hookJSONAgain = redactor.redact(hookJSON.redactedText)
        #expect(hookJSONAgain.redactionCount == 0)
        let hookURL = redactor.redact("https://app:\(hook)@hooks.example/stripe")
        #expect(hookURL.redactedText == "https://app:\(hookKept)@hooks.example/stripe")
        #expect(hookURL.redactionCount == 1)
        let hookURLAgain = redactor.redact(hookURL.redactedText)
        #expect(hookURLAgain.redactionCount == 0)

        let hookFloor = "whsec" + "_" + String(repeating: "d", count: 20)
        #expect(redactor.redact(hookFloor).redactedText == hookKept)
        let hookShort = "whsec" + "_" + String(repeating: "d", count: 19)
        #expect(redactor.redact(hookShort).redactedText == hookShort)
        let mention = redactor.redact("secrets start with whsec_ on Stripe")
        #expect(mention.redactedText == "secrets start with whsec_ on Stripe")
        #expect(mention.redactionCount == 0)
        let hookSentence = redactor.redact("used \(hook). next")
        #expect(hookSentence.redactedText == "used \(hookKept). next")
        let hookQuery = redactor.redact(hook + "?x=1")
        #expect(hookQuery.redactedText == hookKept + "?x=1")
        #expect(hookQuery.redactionCount == 1)

        let hookGlued = "n" + hook
        #expect(redactor.redact(hookGlued).redactedText == hookGlued)
        let hookUnder = "_" + hook
        #expect(redactor.redact(hookUnder).redactedText == hookUnder)
        // `-` or `_` inside the body keeps the whole token, tail included.
        let hyphenated = hookFloor + "-tail"
        #expect(redactor.redact(hyphenated).redactedText == hyphenated)
        let scored = hookFloor + "_tail"
        #expect(redactor.redact(scored).redactedText == scored)

        let both = redactor.redact("\(live) \(hook)")
        #expect(both.redactedText == "\(keptLive) \(hookKept)")
        #expect(both.redactionCount == 2)
        let bothAgain = redactor.redact(both.redactedText)
        #expect(bothAgain.redactionCount == 0)
    }

    @Test("An npm publish token and a PyPI upload token are redacted once and keep their prefix")
    func redactsPackagePublishTokens() {
        let redactor = SecretRedactor()
        let npmBody = "0123456789abcdefghijABCDEFGHIJkl6789"
        #expect(npmBody.count == 36)
        let npm = "npm_" + npmBody
        let npmKept = "npm_[REDACTED]"

        let bare = redactor.redact("published with \(npm)")
        #expect(bare.redactedText == "published with \(npmKept)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(npmBody))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        // `NPM_TOKEN` and `:_authToken` already end in the assignment
        // keyword. The prefix stays, and the placeholder is not a second
        // secret. The `.npmrc` line has no scheme.
        let assigned = redactor.redact("NPM_TOKEN=\(npm)")
        #expect(assigned.redactedText == "NPM_TOKEN=\(npmKept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let npmrc = redactor.redact("//registry.npmjs.org/:_authToken=\(npm)")
        #expect(npmrc.redactedText == "//registry.npmjs.org/:_authToken=\(npmKept)")
        #expect(npmrc.redactionCount == 1)
        let npmrcAgain = redactor.redact(npmrc.redactedText)
        #expect(npmrcAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"token": "\#(npm)"}"#)
        #expect(quoted.redactedText == #"{"token": "\#(npmKept)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let remote = redactor.redact("https://oauth2:\(npm)@registry.npmjs.org/org/pkg")
        #expect(remote.redactedText == "https://oauth2:\(npmKept)@registry.npmjs.org/org/pkg")
        #expect(remote.redactionCount == 1)
        #expect(remote.redactedText.contains("registry.npmjs.org/org/pkg"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        // `@` is still not the end of an ordinary assignment. The tail
        // after a recognized token is not published.
        let leftover = redactor.redact("token=\(npm)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(npmBody))

        let sentence = redactor.redact("saw \(npm). next")
        #expect(sentence.redactedText == "saw \(npmKept). next")
        #expect(sentence.redactionCount == 1)
        let query = redactor.redact(npm + "?x=1")
        #expect(query.redactedText == npmKept + "?x=1")
        #expect(query.redactionCount == 1)
        // A hyphen is not part of the token. The body is gone and the note stays.
        let noted = redactor.redact(npm + "-note")
        #expect(noted.redactedText == npmKept + "-note")
        #expect(noted.redactionCount == 1)
        #expect(!noted.redactedText.contains(npmBody))

        let pypiPrefix = "pypi-" + "AgEIcHlwaS5vcmc"
        let pypiBody = String(repeating: "A", count: 20) + String(repeating: "b", count: 20) + "-_" + String(repeating: "9", count: 8)
        #expect(pypiBody.count == 50)
        let pypi = pypiPrefix + pypiBody
        let pypiKept = "pypi-[REDACTED]"

        let uploaded = redactor.redact("twine upload \(pypi)")
        #expect(uploaded.redactedText == "twine upload \(pypiKept)")
        #expect(uploaded.redactionCount == 1)
        #expect(!uploaded.redactedText.contains(pypiBody))
        #expect(!uploaded.redactedText.contains("AgEIcHlwaS5vcmc"))
        let uploadedAgain = redactor.redact(uploaded.redactedText)
        #expect(uploadedAgain.redactedText == uploaded.redactedText)
        #expect(uploadedAgain.redactionCount == 0)

        let pypirc = redactor.redact("password = \(pypi)")
        #expect(pypirc.redactedText == "password = \(pypiKept)")
        #expect(pypirc.redactionCount == 1)
        let pypircAgain = redactor.redact(pypirc.redactedText)
        #expect(pypircAgain.redactionCount == 0)
        let pypiJSON = redactor.redact(#"{"password": "\#(pypi)"}"#)
        #expect(pypiJSON.redactedText == #"{"password": "\#(pypiKept)"}"#)
        #expect(pypiJSON.redactionCount == 1)
        let pypiJSONAgain = redactor.redact(pypiJSON.redactedText)
        #expect(pypiJSONAgain.redactionCount == 0)
        let pypiURL = redactor.redact("https://user:\(pypi)@upload.pypi.org/legacy/")
        #expect(pypiURL.redactedText == "https://user:\(pypiKept)@upload.pypi.org/legacy/")
        #expect(pypiURL.redactionCount == 1)
        #expect(pypiURL.redactedText.contains("upload.pypi.org/legacy/"))
        let pypiURLAgain = redactor.redact(pypiURL.redactedText)
        #expect(pypiURLAgain.redactionCount == 0)
        let pypiSentence = redactor.redact("saw \(pypi). next")
        #expect(pypiSentence.redactedText == "saw \(pypiKept). next")
        #expect(pypiSentence.redactionCount == 1)

        let pair = redactor.redact("\(npm) \(pypi)")
        #expect(pair.redactedText == "\(npmKept) \(pypiKept)")
        #expect(pair.redactionCount == 2)
        let pairAgain = redactor.redact(pair.redactedText)
        #expect(pairAgain.redactedText == pair.redactedText)
        #expect(pairAgain.redactionCount == 0)

        let maxBody = String(repeating: "c", count: 1000)
        #expect(redactor.redact(pypiPrefix + maxBody).redactedText == pypiKept)
        let kept = [
            "tokens start with npm_ and pypi-AgEIcHlwaS5vcmc",
            "npm_" + String(repeating: "a", count: 35),
            "npm_" + String(repeating: "a", count: 37),
            "NPM_" + npmBody,
            "x" + npm,
            "_" + npm,
            "npm_" + String(repeating: "a", count: 20) + "-" + String(repeating: "b", count: 16),
            pypiPrefix,
            pypiPrefix + String(repeating: "a", count: 49),
            pypiPrefix + String(repeating: "a", count: 1001),
            pypiPrefix + String(repeating: "a", count: 20) + "." + String(repeating: "b", count: 40),
            "x" + pypi,
            "_" + pypi,
        ]
        for line in kept {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
        // A dot after a long enough body ends the match. The tail stays.
        let dotted = pypiPrefix + String(repeating: "a", count: 50) + ".tailsecret"
        let dottedResult = redactor.redact(dotted)
        #expect(dottedResult.redactedText == pypiKept + ".tailsecret")
        #expect(dottedResult.redactionCount == 1)
        #expect(dottedResult.redactedText.contains("tailsecret"))
    }

    @Test("A Hugging Face token and a RubyGems API key are redacted once and keep their prefix")
    func redactsModelAndGemTokens() {
        let redactor = SecretRedactor()
        let hfBody = "abcdefghijklmnopqrstuvwxyzABCDEFGH"
        #expect(hfBody.count == 34)
        let hf = "hf_" + hfBody
        let hfKept = "hf_[REDACTED]"
        let orgBody = String(repeating: "a", count: 17) + String(repeating: "B", count: 17)
        #expect(orgBody.count == 34)
        let org = "api_org_" + orgBody
        let orgKept = "api_org_[REDACTED]"
        let gemBody = String(repeating: "cec9db93", count: 6)
        #expect(gemBody.count == 48)
        let gem = "rubygems_" + gemBody
        let gemKept = "rubygems_[REDACTED]"

        let bare = redactor.redact("downloaded with \(hf)")
        #expect(bare.redactedText == "downloaded with \(hfKept)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(hfBody))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        // `HF_TOKEN` already ends in the assignment keyword. The prefix
        // stays, and the placeholder is not a second secret.
        let assigned = redactor.redact("HF_TOKEN=\(hf)")
        #expect(assigned.redactedText == "HF_TOKEN=\(hfKept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"token": "\#(hf)"}"#)
        #expect(quoted.redactedText == #"{"token": "\#(hfKept)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)
        let remote = redactor.redact("https://user:\(hf)@huggingface.co/org/model")
        #expect(remote.redactedText == "https://user:\(hfKept)@huggingface.co/org/model")
        #expect(remote.redactionCount == 1)
        #expect(remote.redactedText.contains("huggingface.co/org/model"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)
        let sentence = redactor.redact("saw \(hf). next")
        #expect(sentence.redactedText == "saw \(hfKept). next")
        #expect(sentence.redactionCount == 1)
        let query = redactor.redact(hf + "?x=1")
        #expect(query.redactedText == hfKept + "?x=1")
        #expect(query.redactionCount == 1)
        let noted = redactor.redact(hf + "-note")
        #expect(noted.redactedText == hfKept + "-note")
        #expect(noted.redactionCount == 1)
        #expect(!noted.redactedText.contains(hfBody))

        // `@` is still not the end of an ordinary assignment.
        let leftover = redactor.redact("token=\(hf)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(hfBody))

        let orgBare = redactor.redact("org token \(org)")
        #expect(orgBare.redactedText == "org token \(orgKept)")
        #expect(orgBare.redactionCount == 1)
        #expect(!orgBare.redactedText.contains(orgBody))
        let orgAgain = redactor.redact(orgBare.redactedText)
        #expect(orgAgain.redactionCount == 0)
        let orgAssigned = redactor.redact("HF_ORG_TOKEN=\(org)")
        #expect(orgAssigned.redactedText == "HF_ORG_TOKEN=\(orgKept)")
        #expect(orgAssigned.redactionCount == 1)
        let orgAssignedAgain = redactor.redact(orgAssigned.redactedText)
        #expect(orgAssignedAgain.redactionCount == 0)
        let orgJSON = redactor.redact(#"{"token": "\#(org)"}"#)
        #expect(orgJSON.redactedText == #"{"token": "\#(orgKept)"}"#)
        #expect(orgJSON.redactionCount == 1)

        let pushed = redactor.redact("gem push \(gem)")
        #expect(pushed.redactedText == "gem push \(gemKept)")
        #expect(pushed.redactionCount == 1)
        #expect(!pushed.redactedText.contains(gemBody))
        let pushedAgain = redactor.redact(pushed.redactedText)
        #expect(pushedAgain.redactedText == pushed.redactedText)
        #expect(pushedAgain.redactionCount == 0)

        // `GEM_HOST_API_KEY` and the credentials name end in `key`.
        let gemEnv = redactor.redact("GEM_HOST_API_KEY=\(gem)")
        #expect(gemEnv.redactedText == "GEM_HOST_API_KEY=\(gemKept)")
        #expect(gemEnv.redactionCount == 1)
        let gemEnvAgain = redactor.redact(gemEnv.redactedText)
        #expect(gemEnvAgain.redactionCount == 0)
        let creds = redactor.redact(":rubygems_api_key: \(gem)")
        #expect(creds.redactedText == ":rubygems_api_key: \(gemKept)")
        #expect(creds.redactionCount == 1)
        let credsAgain = redactor.redact(creds.redactedText)
        #expect(credsAgain.redactionCount == 0)
        let gemJSON = redactor.redact(#"{"api_key": "\#(gem)"}"#)
        #expect(gemJSON.redactedText == #"{"api_key": "\#(gemKept)"}"#)
        #expect(gemJSON.redactionCount == 1)
        let gemURL = redactor.redact("https://user:\(gem)@rubygems.org/api/v1/gems")
        #expect(gemURL.redactedText == "https://user:\(gemKept)@rubygems.org/api/v1/gems")
        #expect(gemURL.redactionCount == 1)
        #expect(gemURL.redactedText.contains("rubygems.org/api/v1/gems"))
        let gemURLAgain = redactor.redact(gemURL.redactedText)
        #expect(gemURLAgain.redactionCount == 0)
        let gemSentence = redactor.redact("saw \(gem). next")
        #expect(gemSentence.redactedText == "saw \(gemKept). next")
        #expect(gemSentence.redactionCount == 1)

        let pair = redactor.redact("\(hf) \(org) \(gem)")
        #expect(pair.redactedText == "\(hfKept) \(orgKept) \(gemKept)")
        #expect(pair.redactionCount == 3)
        let pairAgain = redactor.redact(pair.redactedText)
        #expect(pairAgain.redactionCount == 0)

        let kept = [
            "tokens start with hf_ and api_org_ and rubygems_",
            "hf_" + String(repeating: "a", count: 33),
            "hf_" + String(repeating: "a", count: 35),
            "hf_" + String(repeating: "a", count: 33) + "1",
            "hf_" + hfBody + "1",
            "HF_" + hfBody,
            "x" + hf,
            "_" + hf,
            "api_org_" + String(repeating: "a", count: 33),
            "api_org_" + String(repeating: "a", count: 35),
            "api_org_" + orgBody + "9",
            "API_ORG_" + orgBody,
            "x" + org,
            "rubygems_" + String(repeating: "ab", count: 16),
            "rubygems_" + String(repeating: "ab", count: 24) + "c",
            "rubygems_701243f217cdf23b1370c7b66b65ca97",
            "rubygems_123456",
            "rubygems_" + gemBody.uppercased(),
            "RUBYGEMS_" + gemBody,
            "x" + gem,
            "_" + gem,
            ":rubygems_api_key: short",
        ]
        for line in kept {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
    }

    @Test("An OpenAI admin key is redacted once, and Bearer keeps that label")
    func redactsOpenAIAdminKeyAndBearerLabel() {
        let redactor = SecretRedactor()
        let body = String(repeating: "a", count: 20) + "-_" + String(repeating: "B", count: 40)
        let admin = "sk-admin-" + body
        let kept = "sk-admin-[REDACTED]"

        let bare = redactor.redact("created \(admin) for the org")
        #expect(bare.redactedText == "created \(kept) for the org")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(body))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        // `OPENAI_ADMIN_KEY` is not an assignment name. The prefix pattern
        // is what takes the value, and the label stays.
        let env = redactor.redact("OPENAI_ADMIN_KEY=\(admin)")
        #expect(env.redactedText == "OPENAI_ADMIN_KEY=\(kept)")
        #expect(env.redactionCount == 1)
        let envAgain = redactor.redact(env.redactedText)
        #expect(envAgain.redactionCount == 0)
        let json = redactor.redact(#"{"OPENAI_ADMIN_KEY": "\#(admin)"}"#)
        #expect(json.redactedText == #"{"OPENAI_ADMIN_KEY": "\#(kept)"}"#)
        #expect(json.redactionCount == 1)
        let jsonAgain = redactor.redact(json.redactedText)
        #expect(jsonAgain.redactionCount == 0)

        let assigned = redactor.redact("token=\(admin)")
        #expect(assigned.redactedText == "token=\(kept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)

        // A header is how the key is pasted. The scheme stays, the label
        // stays, and the body is not a second secret.
        let header = redactor.redact("Authorization: Bearer \(admin)")
        #expect(header.redactedText == "Authorization: Bearer \(kept)")
        #expect(header.redactionCount == 1)
        let headerAgain = redactor.redact(header.redactedText)
        #expect(headerAgain.redactionCount == 0)
        let lower = redactor.redact("authorization: bearer \(admin)")
        #expect(lower.redactedText == "authorization: bearer \(kept)")
        #expect(lower.redactionCount == 1)

        let url = redactor.redact("https://user:\(admin)@api.openai.com/v1")
        #expect(url.redactedText == "https://user:\(kept)@api.openai.com/v1")
        #expect(url.redactionCount == 1)
        let urlAgain = redactor.redact(url.redactedText)
        #expect(urlAgain.redactionCount == 0)

        let sentence = redactor.redact("saw \(admin). next")
        #expect(sentence.redactedText == "saw \(kept). next")
        #expect(sentence.redactionCount == 1)

        let hyphen = redactor.redact("my-\(admin)")
        #expect(hyphen.redactedText == "my-\(kept)")
        #expect(hyphen.redactionCount == 1)

        let exact = "sk-admin-" + String(repeating: "c", count: 20)
        let exactResult = redactor.redact(exact + ". next")
        #expect(exactResult.redactedText == "\(kept). next")
        #expect(exactResult.redactionCount == 1)

        // The same header used to drop the label of every prefix above
        // and count it twice. An opaque token on the same line is still
        // the scheme's own redaction. A JWT after the scheme is still
        // one redaction, not a second `eyJ` token.
        let xai = "xai-" + String(repeating: "a", count: 26)
        let ghp = "ghp_" + String(repeating: "a", count: 36)
        let proj = "sk-proj-" + String(repeating: "b", count: 24)
        let xaiHeader = redactor.redact("Authorization: Bearer \(xai)")
        #expect(xaiHeader.redactedText == "Authorization: Bearer xai-[REDACTED]")
        #expect(xaiHeader.redactionCount == 1)
        let xaiAgain = redactor.redact(xaiHeader.redactedText)
        #expect(xaiAgain.redactionCount == 0)
        let ghpHeader = redactor.redact("authorization: bearer \(ghp).")
        #expect(ghpHeader.redactedText == "authorization: bearer ghp_[REDACTED].")
        #expect(ghpHeader.redactionCount == 1)
        let projHeader = redactor.redact("Bearer \(proj) tail")
        #expect(projHeader.redactedText == "Bearer sk-proj-[REDACTED] tail")
        #expect(projHeader.redactionCount == 1)

        let opaque = "opaquetoken" + "1234567890"
        let mixed = redactor.redact("Bearer \(xai) Bearer \(opaque)")
        #expect(mixed.redactedText == "Bearer xai-[REDACTED] Bearer [REDACTED]")
        #expect(mixed.redactionCount == 2)
        let mixedAgain = redactor.redact(mixed.redactedText)
        #expect(mixedAgain.redactionCount == 0)

        let jwt = "eyJ" + String(repeating: "a", count: 10) + "."
            + String(repeating: "b", count: 10) + "."
            + String(repeating: "c", count: 10)
        let wrapped = redactor.redact("authorization: bearer \(jwt)")
        #expect(wrapped.redactedText == "authorization: Bearer [REDACTED]")
        #expect(wrapped.redactionCount == 1)
        #expect(!wrapped.redactedText.contains("aaaaaaaaaa"))
        let wrappedAgain = redactor.redact(wrapped.redactedText)
        #expect(wrappedAgain.redactionCount == 0)

        // `@` is still not the end of an ordinary value, so the tail
        // does not survive beside the placeholder.
        let leftover = redactor.redact("token=\(admin)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(body))

        let stayed = [
            "keys start with sk-admin-",
            "sk-admin-" + String(repeating: "a", count: 19),
            "SK-ADMIN-" + body,
            "x" + admin,
            "_" + admin,
            "notbearer " + opaque,
        ]
        for line in stayed {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
    }

    @Test("A Groq API key is redacted once and keeps its prefix")
    func redactsGroqKey() {
        let redactor = SecretRedactor()
        let body = String(repeating: "Ab3", count: 17) + "x"
        #expect(body.count == 52)
        let key = "gsk_" + body
        let kept = "gsk_[REDACTED]"

        let bare = redactor.redact("downloaded with \(key)")
        #expect(bare.redactedText == "downloaded with \(kept)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(body))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        // `GROQ_API_KEY` already ends in the assignment keyword. The
        // prefix stays, and the placeholder is not a second secret.
        let assigned = redactor.redact("GROQ_API_KEY=\(key)")
        #expect(assigned.redactedText == "GROQ_API_KEY=\(kept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"api_key": "\#(key)"}"#)
        #expect(quoted.redactedText == #"{"api_key": "\#(kept)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let header = redactor.redact("Authorization: Bearer \(key)")
        #expect(header.redactedText == "Authorization: Bearer \(kept)")
        #expect(header.redactionCount == 1)
        let headerAgain = redactor.redact(header.redactedText)
        #expect(headerAgain.redactionCount == 0)
        let lower = redactor.redact("authorization: bearer \(key)")
        #expect(lower.redactedText == "authorization: bearer \(kept)")
        #expect(lower.redactionCount == 1)

        let remote = redactor.redact("https://user:\(key)@api.groq.com/openai/v1")
        #expect(remote.redactedText == "https://user:\(kept)@api.groq.com/openai/v1")
        #expect(remote.redactionCount == 1)
        #expect(remote.redactedText.contains("api.groq.com/openai/v1"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        let sentence = redactor.redact("saw \(key). next")
        #expect(sentence.redactedText == "saw \(kept). next")
        #expect(sentence.redactionCount == 1)
        let noted = redactor.redact(key + "-note")
        #expect(noted.redactedText == kept + "-note")
        #expect(noted.redactionCount == 1)
        #expect(!noted.redactedText.contains(body))
        let hyphen = redactor.redact("my-\(key)")
        #expect(hyphen.redactedText == "my-\(kept)")
        #expect(hyphen.redactionCount == 1)

        // `@` is still not the end of an ordinary assignment.
        let leftover = redactor.redact("token=\(key)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(body))

        let keptLines = [
            "keys start with gsk_",
            "gsk_" + String(repeating: "a", count: 51),
            "gsk_" + String(repeating: "a", count: 53),
            "gsk_" + body + "1",
            "gsk_" + String(body.prefix(20)) + "_" + String(body.dropFirst(20)),
            "gsk_your_secret_key_here",
            "GSK_" + body,
            "x" + key,
            "_" + key,
        ]
        for line in keptLines {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
    }

    @Test("A Perplexity API key is redacted once and keeps its prefix")
    func redactsPerplexityKey() {
        let redactor = SecretRedactor()
        let body = String(repeating: "Ab3", count: 16)
        #expect(body.count == 48)
        let key = "pplx-" + body
        let kept = "pplx-[REDACTED]"

        let bare = redactor.redact("searched with \(key)")
        #expect(bare.redactedText == "searched with \(kept)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(body))
        let bareAgain = redactor.redact(bare.redactedText)
        #expect(bareAgain.redactedText == bare.redactedText)
        #expect(bareAgain.redactionCount == 0)

        // `PERPLEXITY_API_KEY` already ends in the assignment keyword.
        // The prefix stays, and the placeholder is not a second secret.
        let assigned = redactor.redact("PERPLEXITY_API_KEY=\(key)")
        #expect(assigned.redactedText == "PERPLEXITY_API_KEY=\(kept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"api_key": "\#(key)"}"#)
        #expect(quoted.redactedText == #"{"api_key": "\#(kept)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let header = redactor.redact("Authorization: Bearer \(key)")
        #expect(header.redactedText == "Authorization: Bearer \(kept)")
        #expect(header.redactionCount == 1)
        let headerAgain = redactor.redact(header.redactedText)
        #expect(headerAgain.redactionCount == 0)
        let lower = redactor.redact("authorization: bearer \(key)")
        #expect(lower.redactedText == "authorization: bearer \(kept)")
        #expect(lower.redactionCount == 1)

        let remote = redactor.redact("https://user:\(key)@api.perplexity.ai/chat")
        #expect(remote.redactedText == "https://user:\(kept)@api.perplexity.ai/chat")
        #expect(remote.redactionCount == 1)
        #expect(remote.redactedText.contains("api.perplexity.ai/chat"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        let sentence = redactor.redact("saw \(key). next")
        #expect(sentence.redactedText == "saw \(kept). next")
        #expect(sentence.redactionCount == 1)
        let noted = redactor.redact(key + "-note")
        #expect(noted.redactedText == kept + "-note")
        #expect(noted.redactionCount == 1)
        #expect(!noted.redactedText.contains(body))
        let hyphen = redactor.redact("my-\(key)")
        #expect(hyphen.redactedText == "my-\(kept)")
        #expect(hyphen.redactionCount == 1)

        // `@` is still not the end of an ordinary assignment.
        let leftover = redactor.redact("token=\(key)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(body))

        let keptLines = [
            "models include pplx-70b and pplx-api",
            "keys start with pplx-",
            "pplx-" + String(repeating: "a", count: 47),
            "pplx-" + String(repeating: "a", count: 49),
            "pplx-" + body + "1",
            "pplx-" + String(body.prefix(20)) + "-" + String(body.dropFirst(20)),
            "PPLX-" + body,
            "x" + key,
            "_" + key,
        ]
        for line in keptLines {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
    }

    @Test("A Doppler token is redacted once and keeps its prefix")
    func redactsDopplerToken() {
        let redactor = SecretRedactor()
        // Doppler's published sample body is 43 alphanumeric characters,
        // inside the 40...44 range their scanner names.
        let sample = "bAqhcVzrhy5cRHkOlNTc0Ve6w5NUDCpcutm8vGE9myi"
        #expect(sample.count == 43)
        let body40 = String(repeating: "a", count: 40)
        let body44 = String(repeating: "B", count: 44)

        let prefixes = [
            "dp.ct.", "dp.pt.", "dp.sa.", "dp.said.", "dp.scim.", "dp.audit.",
        ]
        for prefix in prefixes {
            let key = prefix + sample
            let kept = prefix + "[REDACTED]"
            let bare = redactor.redact("fetched \(key)")
            #expect(bare.redactedText == "fetched \(kept)")
            #expect(bare.redactionCount == 1)
            #expect(!bare.redactedText.contains(sample))
            let again = redactor.redact(bare.redactedText)
            #expect(again.redactedText == bare.redactedText)
            #expect(again.redactionCount == 0)
        }

        // The config slug is not the secret. Both shapes keep `dp.st.`.
        let service = "dp.st." + sample
        let configured = "dp.st.dev." + sample
        let hyphenConfig = "dp.st.my-config." + body40
        let underscoreConfig = "dp.st.my_config." + body44
        for key in [service, configured, hyphenConfig, underscoreConfig] {
            let result = redactor.redact(key)
            #expect(result.redactedText == "dp.st.[REDACTED]")
            #expect(result.redactionCount == 1)
            #expect(!result.redactedText.contains(sample))
            #expect(!result.redactedText.contains(body40))
            #expect(!result.redactedText.contains(body44))
            let again = redactor.redact(result.redactedText)
            #expect(again.redactionCount == 0)
        }

        // `DOPPLER_TOKEN` already ends in the assignment keyword. The
        // prefix stays, and the placeholder is not a second secret.
        let cli = "dp.ct." + sample
        let kept = "dp.ct.[REDACTED]"
        let assigned = redactor.redact("DOPPLER_TOKEN=\(configured)")
        #expect(assigned.redactedText == "DOPPLER_TOKEN=dp.st.[REDACTED]")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"token": "\#(cli)"}"#)
        #expect(quoted.redactedText == #"{"token": "\#(kept)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let header = redactor.redact("Authorization: Bearer \(configured)")
        #expect(header.redactedText == "Authorization: Bearer dp.st.[REDACTED]")
        #expect(header.redactionCount == 1)
        let headerAgain = redactor.redact(header.redactedText)
        #expect(headerAgain.redactionCount == 0)
        let lower = redactor.redact("authorization: bearer \(cli)")
        #expect(lower.redactedText == "authorization: bearer \(kept)")
        #expect(lower.redactionCount == 1)

        let remote = redactor.redact("https://user:\(cli)@api.doppler.com/v3")
        #expect(remote.redactedText == "https://user:\(kept)@api.doppler.com/v3")
        #expect(remote.redactionCount == 1)
        #expect(remote.redactedText.contains("api.doppler.com/v3"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        let sentence = redactor.redact("saw \(cli). next")
        #expect(sentence.redactedText == "saw \(kept). next")
        #expect(sentence.redactionCount == 1)
        let noted = redactor.redact(service + "-note")
        #expect(noted.redactedText == "dp.st.[REDACTED]-note")
        #expect(noted.redactionCount == 1)
        #expect(!noted.redactedText.contains(sample))
        let hyphen = redactor.redact("my-\(cli)")
        #expect(hyphen.redactedText == "my-\(kept)")
        #expect(hyphen.redactionCount == 1)

        let short = redactor.redact("dp.ct." + body40)
        #expect(short.redactedText == "dp.ct.[REDACTED]")
        #expect(short.redactionCount == 1)
        let long = redactor.redact("dp.pt." + body44)
        #expect(long.redactedText == "dp.pt.[REDACTED]")
        #expect(long.redactionCount == 1)

        let pair = redactor.redact("\(cli) and \(configured)")
        #expect(pair.redactedText == "\(kept) and dp.st.[REDACTED]")
        #expect(pair.redactionCount == 2)

        // `@` is still not the end of an ordinary assignment.
        let leftover = redactor.redact("token=\(cli)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(sample))

        let keptLines = [
            "tokens start with dp.ct.",
            "dp.ct." + String(repeating: "a", count: 39),
            "dp.ct." + String(repeating: "a", count: 45),
            "dp.ct." + body44 + "1",
            "dp.ct." + String(sample.prefix(20)) + "-" + String(sample.dropFirst(20)),
            "DP.CT." + sample,
            "DP.ST.DEV." + sample,
            "x" + cli,
            "_" + cli,
            // A one-character config, an uppercase config, and a config
            // longer than 35 are not the shape Doppler's scanner names.
            "dp.st.d." + sample,
            "dp.st.Dev." + sample,
            "dp.st." + String(repeating: "c", count: 36) + "." + body40,
        ]
        for line in keptLines {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
    }

    @Test("An age identity is redacted once and keeps its prefix")
    func redactsAgeSecretKey() {
        let redactor = SecretRedactor()
        // age-keygen writes exactly 58 characters from the Bech32
        // alphabet after `AGE-SECRET-KEY-1`. `Q` is in that alphabet.
        let body = String(repeating: "Q", count: 58)
        #expect(body.count == 58)
        let alphabet = "QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L"
        let mixed = String(String(repeating: alphabet, count: 2).prefix(58))
        #expect(mixed.count == 58)
        let key = "AGE-SECRET-KEY-1" + body
        let mixedKey = "AGE-SECRET-KEY-1" + mixed
        let kept = "AGE-SECRET-KEY-1[REDACTED]"

        let bare = redactor.redact("age-keygen wrote \(key)")
        #expect(bare.redactedText == "age-keygen wrote \(kept)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(body))
        let again = redactor.redact(bare.redactedText)
        #expect(again.redactedText == bare.redactedText)
        #expect(again.redactionCount == 0)

        let other = redactor.redact(mixedKey)
        #expect(other.redactedText == kept)
        #expect(other.redactionCount == 1)
        #expect(!other.redactedText.contains(mixed))

        // The public key on the line above is not the identity.
        let generated = """
        # public key: age1ql3z7hjy9xx0qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsq9vzp6
        \(key)
        """
        let file = redactor.redact(generated)
        #expect(file.redactedText.contains("age1ql3z7hjy9xx0qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsq9vzp6"))
        #expect(file.redactedText.contains(kept))
        #expect(!file.redactedText.contains(body))
        #expect(file.redactionCount == 1)
        let fileAgain = redactor.redact(file.redactedText)
        #expect(fileAgain.redactionCount == 0)

        // `AGE_SECRET_KEY` already ends in the assignment keyword. The
        // prefix stays, and the placeholder is not a second secret.
        let assigned = redactor.redact("AGE_SECRET_KEY=\(key)")
        #expect(assigned.redactedText == "AGE_SECRET_KEY=\(kept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"token": "\#(mixedKey)"}"#)
        #expect(quoted.redactedText == #"{"token": "\#(kept)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let header = redactor.redact("Authorization: Bearer \(key)")
        #expect(header.redactedText == "Authorization: Bearer \(kept)")
        #expect(header.redactionCount == 1)
        let headerAgain = redactor.redact(header.redactedText)
        #expect(headerAgain.redactionCount == 0)
        let lower = redactor.redact("authorization: bearer \(mixedKey)")
        #expect(lower.redactedText == "authorization: bearer \(kept)")
        #expect(lower.redactionCount == 1)

        let remote = redactor.redact("https://user:\(key)@keys.example/identity")
        #expect(remote.redactedText == "https://user:\(kept)@keys.example/identity")
        #expect(remote.redactionCount == 1)
        #expect(remote.redactedText.contains("keys.example/identity"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        let sentence = redactor.redact("saw \(key). next")
        #expect(sentence.redactedText == "saw \(kept). next")
        #expect(sentence.redactionCount == 1)
        let noted = redactor.redact(key + "-note")
        #expect(noted.redactedText == kept + "-note")
        #expect(noted.redactionCount == 1)
        #expect(!noted.redactedText.contains(body))
        let hyphen = redactor.redact("my-\(key)")
        #expect(hyphen.redactedText == "my-\(kept)")
        #expect(hyphen.redactionCount == 1)

        let pair = redactor.redact("\(key) and \(mixedKey)")
        #expect(pair.redactedText == "\(kept) and \(kept)")
        #expect(pair.redactionCount == 2)

        // `@` is still not the end of an ordinary assignment.
        let leftover = redactor.redact("token=\(key)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(body))

        let keptLines = [
            "age-keygen writes AGE-SECRET-KEY-1",
            "AGE-SECRET-KEY-1" + String(repeating: "Q", count: 57),
            "AGE-SECRET-KEY-1" + String(repeating: "Q", count: 59),
            key + "Q",
            key + "1",
            "AGE-SECRET-KEY-1" + String(repeating: "Q", count: 20) + "B" + String(repeating: "Q", count: 37),
            "AGE-SECRET-KEY-1" + String(repeating: "Q", count: 20) + "I" + String(repeating: "Q", count: 37),
            "AGE-SECRET-KEY-1" + String(repeating: "Q", count: 20) + "O" + String(repeating: "Q", count: 37),
            "AGE-SECRET-KEY-1" + String(repeating: "Q", count: 20) + "-" + String(repeating: "Q", count: 37),
            "age-secret-key-1" + body,
            "x" + key,
            "_" + key,
            "age1ql3z7hjy9xx0qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsq9vzp6",
        ]
        for line in keptLines {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
    }

    @Test("A Supabase secret key is redacted once and keeps its prefix")
    func redactsSupabaseSecretKey() {
        let redactor = SecretRedactor()
        // Docs: sb_secret_ + 22 base64url + _ + 8 base64url. The hyphen
        // and underscore are in that alphabet, so both segments use them.
        let random = "Ab3-Ef_9Gh1-Jk_2Mn4-Pq"
        let checksum = "Zx-9_Q2w"
        #expect(random.count == 22)
        #expect(checksum.count == 8)
        let body = random + "_" + checksum
        let plainRandom = String(repeating: "A", count: 22)
        let plainChecksum = String(repeating: "B", count: 8)
        let key = "sb_secret_" + body
        let plain = "sb_secret_" + plainRandom + "_" + plainChecksum
        let kept = "sb_secret_[REDACTED]"

        let bare = redactor.redact("supabase status printed \(key)")
        #expect(bare.redactedText == "supabase status printed \(kept)")
        #expect(bare.redactionCount == 1)
        #expect(!bare.redactedText.contains(body))
        let again = redactor.redact(bare.redactedText)
        #expect(again.redactedText == bare.redactedText)
        #expect(again.redactionCount == 0)

        let other = redactor.redact(plain)
        #expect(other.redactedText == kept)
        #expect(other.redactionCount == 1)
        #expect(!other.redactedText.contains(plainChecksum))

        // The publishable key is the client identifier. Same shape,
        // different prefix, and it stays beside the secret.
        let publishable = "sb_publishable_" + body
        let both = redactor.redact("\(publishable) \(key)")
        #expect(both.redactedText == "\(publishable) \(kept)")
        #expect(both.redactionCount == 1)
        #expect(both.redactedText.contains(publishable))

        // `SUPABASE_SECRET_KEY` already ends in the assignment keyword.
        // `apikey` is how the gateway reads the key. The prefix stays,
        // and the placeholder is not a second secret.
        let assigned = redactor.redact("SUPABASE_SECRET_KEY=\(key)")
        #expect(assigned.redactedText == "SUPABASE_SECRET_KEY=\(kept)")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let wire = redactor.redact("apikey: \(plain)")
        #expect(wire.redactedText == "apikey: \(kept)")
        #expect(wire.redactionCount == 1)
        let wireAgain = redactor.redact(wire.redactedText)
        #expect(wireAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"apikey": "\#(key)"}"#)
        #expect(quoted.redactedText == #"{"apikey": "\#(kept)"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let header = redactor.redact("Authorization: Bearer \(key)")
        #expect(header.redactedText == "Authorization: Bearer \(kept)")
        #expect(header.redactionCount == 1)
        let headerAgain = redactor.redact(header.redactedText)
        #expect(headerAgain.redactionCount == 0)
        let lower = redactor.redact("authorization: bearer \(plain)")
        #expect(lower.redactedText == "authorization: bearer \(kept)")
        #expect(lower.redactionCount == 1)

        let remote = redactor.redact("https://user:\(key)@db.example.supabase.co/postgres")
        #expect(remote.redactedText == "https://user:\(kept)@db.example.supabase.co/postgres")
        #expect(remote.redactionCount == 1)
        #expect(remote.redactedText.contains("db.example.supabase.co/postgres"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        let sentence = redactor.redact("saw \(key). next")
        #expect(sentence.redactedText == "saw \(kept). next")
        #expect(sentence.redactionCount == 1)
        let hyphen = redactor.redact("my-\(key)")
        #expect(hyphen.redactedText == "my-\(kept)")
        #expect(hyphen.redactionCount == 1)

        let pair = redactor.redact("\(key) and \(plain)")
        #expect(pair.redactedText == "\(kept) and \(kept)")
        #expect(pair.redactionCount == 2)

        // `@` is still not the end of an ordinary assignment.
        let leftover = redactor.redact("token=\(key)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(body))

        let keptLines = [
            "keys start with sb_secret_",
            "sb_secret_" + String(repeating: "A", count: 21) + "_" + plainChecksum,
            "sb_secret_" + String(repeating: "A", count: 23) + "_" + plainChecksum,
            "sb_secret_" + plainRandom + "_" + String(repeating: "B", count: 7),
            "sb_secret_" + plainRandom + "_" + String(repeating: "B", count: 9),
            plain + "B",
            plain + "-note",
            "sb_secret_" + String(repeating: "A", count: 10) + "+" + String(repeating: "A", count: 11) + "_" + plainChecksum,
            "sb_secret_" + String(repeating: "A", count: 10) + "/" + String(repeating: "A", count: 11) + "_" + plainChecksum,
            "sb_secret_" + String(repeating: "A", count: 10) + "=" + String(repeating: "A", count: 11) + "_" + plainChecksum,
            "SB_SECRET_" + plainRandom + "_" + plainChecksum,
            "x" + key,
            "_" + key,
            publishable,
            "sb_temp_" + body,
            "sb_secret_...",
        ]
        for line in keptLines {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
    }

    @Test("A Supabase access token is redacted once and keeps its prefix")
    func redactsSupabaseAccessToken() {
        let redactor = SecretRedactor()
        // The CLI accepts sbp_, sbp_v0_, and sbp_oauth_, each plus 40
        // lowercase hex characters.
        let hex = String(repeating: "0123456789abcdef", count: 2) + "01234567"
        #expect(hex.count == 40)
        let forms = ["sbp_", "sbp_v0_", "sbp_oauth_"]
        for prefix in forms {
            let key = prefix + hex
            let kept = prefix + "[REDACTED]"
            let bare = redactor.redact("supabase login showed \(key)")
            #expect(bare.redactedText == "supabase login showed \(kept)")
            #expect(bare.redactionCount == 1)
            #expect(!bare.redactedText.contains(hex))
            let again = redactor.redact(bare.redactedText)
            #expect(again.redactedText == bare.redactedText)
            #expect(again.redactionCount == 0)
        }

        let key = "sbp_" + hex
        let versioned = "sbp_v0_" + hex
        let oauth = "sbp_oauth_" + String(repeating: "a", count: 40)
        let kept = "sbp_[REDACTED]"

        // `SUPABASE_ACCESS_TOKEN` already ends in the assignment keyword.
        let assigned = redactor.redact("SUPABASE_ACCESS_TOKEN=\(versioned)")
        #expect(assigned.redactedText == "SUPABASE_ACCESS_TOKEN=sbp_v0_[REDACTED]")
        #expect(assigned.redactionCount == 1)
        let assignedAgain = redactor.redact(assigned.redactedText)
        #expect(assignedAgain.redactionCount == 0)
        let quoted = redactor.redact(#"{"token": "\#(oauth)"}"#)
        #expect(quoted.redactedText == #"{"token": "sbp_oauth_[REDACTED]"}"#)
        #expect(quoted.redactionCount == 1)
        let quotedAgain = redactor.redact(quoted.redactedText)
        #expect(quotedAgain.redactionCount == 0)

        let header = redactor.redact("Authorization: Bearer \(key)")
        #expect(header.redactedText == "Authorization: Bearer \(kept)")
        #expect(header.redactionCount == 1)
        let headerAgain = redactor.redact(header.redactedText)
        #expect(headerAgain.redactionCount == 0)
        let lower = redactor.redact("authorization: bearer \(versioned)")
        #expect(lower.redactedText == "authorization: bearer sbp_v0_[REDACTED]")
        #expect(lower.redactionCount == 1)

        // The management token is also the password in the pooler URL.
        let remote = redactor.redact("postgres://postgres:\(key)@db.example.supabase.co/postgres")
        #expect(remote.redactedText == "postgres://postgres:\(kept)@db.example.supabase.co/postgres")
        #expect(remote.redactionCount == 1)
        #expect(remote.redactedText.contains("db.example.supabase.co/postgres"))
        let remoteAgain = redactor.redact(remote.redactedText)
        #expect(remoteAgain.redactionCount == 0)

        let sentence = redactor.redact("saw \(oauth). next")
        #expect(sentence.redactedText == "saw sbp_oauth_[REDACTED]. next")
        #expect(sentence.redactionCount == 1)
        let noted = redactor.redact(key + "-note")
        #expect(noted.redactedText == kept + "-note")
        #expect(noted.redactionCount == 1)
        #expect(!noted.redactedText.contains(hex))
        let hyphen = redactor.redact("my-\(versioned)")
        #expect(hyphen.redactedText == "my-sbp_v0_[REDACTED]")
        #expect(hyphen.redactionCount == 1)

        let pair = redactor.redact("\(key) and \(versioned)")
        #expect(pair.redactedText == "\(kept) and sbp_v0_[REDACTED]")
        #expect(pair.redactionCount == 2)

        let leftover = redactor.redact("token=\(oauth)@leftoversecret")
        #expect(leftover.redactedText == "token=[REDACTED]")
        #expect(leftover.redactionCount == 2)
        #expect(!leftover.redactedText.contains("leftoversecret"))
        #expect(!leftover.redactedText.contains(oauth))

        let keptLines = [
            "tokens start with sbp_",
            "sbp_" + String(repeating: "a", count: 39),
            "sbp_" + String(repeating: "a", count: 41),
            key + "a",
            "sbp_" + String(repeating: "A", count: 40),
            "sbp_v0_" + String(repeating: "A", count: 40),
            "sbp_oauth_" + String(repeating: "a", count: 39),
            "sbp_v1_" + hex,
            "sbp_OAUTH_" + String(repeating: "a", count: 40),
            "SBP_" + hex,
            "x" + key,
            "_" + versioned,
            "sbp_not-a-token",
        ]
        for line in keptLines {
            let result = redactor.redact(line)
            #expect(result.redactionCount == 0, "redacted \(line.prefix(80))")
            #expect(result.redactedText == line)
        }
    }
}

// MARK: - DwellTracker Tests

@Suite("DwellTracker")
struct DwellTrackerTests {
    @Test("Update and retrieve entry")
    func updateAndRetrieve() {
        let tracker = DwellTracker()
        let id = AgentID("w1:p1")
        let now = Date()
        tracker.update(agentId: id, status: .blocked, enteredAt: now, lastOutputAt: now)

        let entry = tracker.entry(for: id)
        #expect(entry != nil)
        #expect(entry?.status == .blocked)
    }

    @Test("Remove entry")
    func removeEntry() {
        let tracker = DwellTracker()
        let id = AgentID("w1:p1")
        tracker.update(agentId: id, status: .idle, enteredAt: Date(), lastOutputAt: nil)
        tracker.remove(agentId: id)
        #expect(tracker.entry(for: id) == nil)
    }
}

// MARK: - DwellTracker Persistence Tests

@Suite("DwellTracker persistence")
struct DwellTrackerPersistenceTests {

    @Test("save() then load(currentAgents:) round-trips entries")
    func saveAndLoadRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let tracker1 = DwellTracker(fileURL: fileURL)
        let agentId = AgentID("w1:p1")
        let now = Date()
        tracker1.update(
            agentId: agentId,
            status: .working,
            enteredAt: now,
            lastOutputAt: now,
            occupantFingerprint: "claude",
            stateChangeSeq: 5
        )
        tracker1.save()

        // Create a new tracker and load
        let tracker2 = DwellTracker(fileURL: fileURL)
        let currentAgents: [AgentID: Agent] = [
            agentId: Agent(
                id: agentId,
                kind: .claude,
                status: .working,
                stateChangeSeq: 5
            )
        ]
        let restored = tracker2.load(currentAgents: currentAgents)
        #expect(restored.count == 1)

        let entry = tracker2.entry(for: agentId)
        #expect(entry != nil)
        #expect(entry?.status == .working)
        #expect(entry?.occupantFingerprint == "claude")
        #expect(entry?.stateChangeSeq == 5)

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Restore guard: fingerprint mismatch discards entry")
    func fingerprintMismatchDiscardsEntry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let tracker1 = DwellTracker(fileURL: fileURL)
        let agentId = AgentID("w1:p1")
        let now = Date()
        tracker1.update(
            agentId: agentId,
            status: .working,
            enteredAt: now,
            lastOutputAt: now,
            occupantFingerprint: "claude",
            stateChangeSeq: 5
        )
        tracker1.save()

        // Load with a different fingerprint (opencode instead of claude)
        let tracker2 = DwellTracker(fileURL: fileURL)
        let currentAgents: [AgentID: Agent] = [
            agentId: Agent(
                id: agentId,
                kind: .opencode, // Different kind!
                status: .working,
                stateChangeSeq: 5
            )
        ]
        let restored = tracker2.load(currentAgents: currentAgents)
        #expect(restored.count == 0, "Entry should be discarded when fingerprint doesn't match")
        #expect(tracker2.entry(for: agentId) == nil)

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Restore guard: stateChangeSeq mismatch discards entry")
    func stateChangeSeqMismatchDiscardsEntry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let tracker1 = DwellTracker(fileURL: fileURL)
        let agentId = AgentID("w1:p1")
        let now = Date()
        tracker1.update(
            agentId: agentId,
            status: .working,
            enteredAt: now,
            lastOutputAt: now,
            occupantFingerprint: "claude",
            stateChangeSeq: 5
        )
        tracker1.save()

        // Load with a different stateChangeSeq (10 instead of 5)
        let tracker2 = DwellTracker(fileURL: fileURL)
        let currentAgents: [AgentID: Agent] = [
            agentId: Agent(
                id: agentId,
                kind: .claude,
                status: .working,
                stateChangeSeq: 10 // Different seq!
            )
        ]
        let restored = tracker2.load(currentAgents: currentAgents)
        #expect(restored.count == 0, "Entry should be discarded when stateChangeSeq doesn't match")
        #expect(tracker2.entry(for: agentId) == nil)

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("The settings fingerprint does not include the session")
    func fingerprintIgnoresSession() {
        let plain = Agent(id: AgentID("wA:p1"), kind: .claude, status: .blocked, stateChangeSeq: 5)
        let named = Agent(
            id: AgentID("wA:p1"), kind: .claude, status: .blocked, stateChangeSeq: 5,
            sessionIdentity: "agent|claude|session|abc"
        )
        #expect(DwellTracker.fingerprint(for: plain) == "claude")
        #expect(DwellTracker.fingerprint(for: named) == DwellTracker.fingerprint(for: plain))
        let custom = Agent(id: AgentID("wA:p1"), kind: .custom("claude"), status: .blocked, stateChangeSeq: 5)
        let customNamed = Agent(
            id: AgentID("wA:p1"), kind: .custom("claude"), status: .blocked, stateChangeSeq: 5,
            sessionIdentity: "agent|claude|session|abc"
        )
        #expect(DwellTracker.fingerprint(for: custom) == "custom:claude")
        #expect(DwellTracker.fingerprint(for: customNamed) == DwellTracker.fingerprint(for: custom))
    }

    @Test("A different session does not inherit the saved dwell, and the same one does")
    func sessionMismatchDiscardsDwell() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")
        let id = AgentID("wA:p1")
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = Agent(
            id: id, kind: .claude, status: .blocked, stateChangeSeq: 5,
            enteredAt: earlier, sessionIdentity: "agent|claude|session|abc"
        )
        let writer = DwellTracker(fileURL: fileURL)
        writer.sync(liveAgents: [id: saved])
        writer.save()

        let same = Agent(
            id: id, kind: .claude, status: .blocked, stateChangeSeq: 5,
            sessionIdentity: "agent|claude|session|abc"
        )
        let restored = DwellTracker(fileURL: fileURL).load(currentAgents: [id: same])
        #expect(restored[id]?.enteredAt == earlier)
        #expect(restored[id]?.sessionIdentity == "agent|claude|session|abc")
        #expect(restored[id]?.occupantFingerprint == "claude")

        let other = Agent(
            id: id, kind: .claude, status: .blocked, stateChangeSeq: 5,
            sessionIdentity: "agent|claude|session|other"
        )
        let refused = DwellTracker(fileURL: fileURL).load(currentAgents: [id: other])
        #expect(refused.isEmpty)
    }

    @Test("A dwell file with no session still matches a row that has one")
    func missingSessionOnDiskStillRestores() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")
        let id = AgentID("wA:p1")
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = Agent(
            id: id, kind: .claude, status: .blocked, stateChangeSeq: 5, enteredAt: earlier
        )
        let writer = DwellTracker(fileURL: fileURL)
        writer.sync(liveAgents: [id: saved])
        writer.save()
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!text.contains("sessionIdentity"))

        let live = Agent(
            id: id, kind: .claude, status: .blocked, stateChangeSeq: 5,
            sessionIdentity: "agent|claude|session|abc"
        )
        let restored = DwellTracker(fileURL: fileURL).load(currentAgents: [id: live])
        #expect(restored[id]?.enteredAt == earlier)
        #expect(restored[id]?.sessionIdentity == nil)
    }

    @Test("A live row that has not named a session still takes the saved dwell")
    func omittedLiveSessionStillRestores() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")
        let id = AgentID("wA:p1")
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = Agent(
            id: id, kind: .claude, status: .blocked, stateChangeSeq: 5,
            enteredAt: earlier, sessionIdentity: "agent|claude|session|abc"
        )
        let writer = DwellTracker(fileURL: fileURL)
        writer.sync(liveAgents: [id: saved])
        writer.save()

        let live = Agent(id: id, kind: .claude, status: .blocked, stateChangeSeq: 5)
        let restored = DwellTracker(fileURL: fileURL).load(currentAgents: [id: live])
        #expect(restored[id]?.enteredAt == earlier)
        #expect(restored[id]?.sessionIdentity == "agent|claude|session|abc")
    }

    @Test("load ignores an oversized dwell-state file")
    func loadRejectsOversize() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")
        try Data(repeating: 0x61, count: DwellTracker.maxFileBytes + 1).write(to: fileURL)

        let tracker = DwellTracker(fileURL: fileURL)
        let restored = tracker.load(currentAgents: [
            AgentID("w1:p1"): Agent(id: AgentID("w1:p1"), kind: .claude, status: .working)
        ])
        #expect(restored.isEmpty)
        #expect(tracker.entry(for: AgentID("w1:p1")) == nil)
    }

    @Test("An oversized dwell-state file is replaced by a compact snapshot of the live herd")
    func saveReplacesOversizedFile() throws {
        // load used to disable saving for good once the file passed the
        // cap, so a file bloated by closed panes stayed that way forever.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")
        try Data(repeating: 0x61, count: DwellTracker.maxFileBytes + 1).write(to: fileURL)

        let id = AgentID("w1:p1")
        let live = [id: Agent(id: id, kind: .claude, status: .working, stateChangeSeq: 4)]
        let tracker = DwellTracker(fileURL: fileURL)
        tracker.sync(liveAgents: live)
        #expect(tracker.load(currentAgents: live).isEmpty)
        tracker.save()

        let written = try Data(contentsOf: fileURL)
        #expect(written.count < DwellTracker.maxFileBytes)
        let reloaded = DwellTracker(fileURL: fileURL).load(currentAgents: live)
        #expect(reloaded[id]?.stateChangeSeq == 4)
        #expect(reloaded[id]?.status == .working)
    }

    @Test("A snapshot larger than the cap is not written")
    func saveSkipsOversizedSnapshot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")
        let marker = Data("{\"entries\":[]}".utf8)
        try marker.write(to: fileURL)

        var herd: [AgentID: Agent] = [:]
        for index in 0..<3000 {
            let id = AgentID("w1:p\(index)")
            herd[id] = Agent(id: id, kind: .custom("agent-\(index)"), status: .working, stateChangeSeq: 1)
        }
        let tracker = DwellTracker(fileURL: fileURL)
        tracker.sync(liveAgents: herd)
        tracker.save()
        #expect(try Data(contentsOf: fileURL) == marker)
    }

    @Test("sync forgets panes that left the herd, and save drops them from the file")
    func syncForgetsClosedPanes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let kept = AgentID("w1:p1")
        let closed = AgentID("w1:p2")
        let tracker = DwellTracker(fileURL: fileURL)
        tracker.sync(liveAgents: [
            kept: Agent(id: kept, kind: .claude, status: .blocked, stateChangeSeq: 3),
            closed: Agent(id: closed, kind: .codex, status: .working, stateChangeSeq: 7),
        ])
        #expect(tracker.allEntries().count == 2)

        tracker.sync(liveAgents: [kept: Agent(id: kept, kind: .claude, status: .blocked, stateChangeSeq: 3)])
        #expect(tracker.entry(for: closed) == nil)
        #expect(tracker.entry(for: kept)?.occupantFingerprint == "claude")
        tracker.save()

        // Even a pane that came back with the same kind and seq is not
        // restored from the save made after it closed.
        let reloaded = DwellTracker(fileURL: fileURL).load(currentAgents: [
            kept: Agent(id: kept, kind: .claude, status: .blocked, stateChangeSeq: 3),
            closed: Agent(id: closed, kind: .codex, status: .working, stateChangeSeq: 7),
        ])
        #expect(Set(reloaded.keys) == [kept])
    }

    @Test("load drops saved panes with no live match and keeps synced live ones")
    func loadDropsUnmatchedEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let restoredId = AgentID("w1:p1")
        let goneId = AgentID("w1:p2")
        let newId = AgentID("w1:p3")
        let longAgo = Date().addingTimeInterval(-3600)
        let writer = DwellTracker(fileURL: fileURL)
        writer.update(agentId: restoredId, status: .blocked, enteredAt: longAgo, lastOutputAt: nil,
                      occupantFingerprint: "claude", stateChangeSeq: 6)
        writer.update(agentId: goneId, status: .working, enteredAt: longAgo, lastOutputAt: nil,
                      occupantFingerprint: "codex", stateChangeSeq: 2)
        writer.save()

        let live = [
            restoredId: Agent(id: restoredId, kind: .claude, status: .blocked, stateChangeSeq: 6),
            newId: Agent(id: newId, kind: .gemini, status: .working, stateChangeSeq: 1),
        ]
        let tracker = DwellTracker(fileURL: fileURL)
        tracker.sync(liveAgents: live)
        let restored = tracker.load(currentAgents: live)

        #expect(Set(restored.keys) == [restoredId])
        #expect(Set(tracker.allEntries().keys) == [restoredId, newId])
        #expect(tracker.entry(for: restoredId)?.enteredAt == restored[restoredId]?.enteredAt)
    }

    @Test("Restore guard: a seq of 0 never restores")
    func zeroSeqDoesNotRestore() throws {
        // After a herdr restart a reused pane id running the same kind
        // starts again at seq 0; kind alone must not hand it a dead
        // episode's enteredAt.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let id = AgentID("w1:p1")
        let writer = DwellTracker(fileURL: fileURL)
        writer.update(agentId: id, status: .working, enteredAt: Date().addingTimeInterval(-86_400),
                      lastOutputAt: nil, occupantFingerprint: "claude", stateChangeSeq: 0)
        writer.save()

        let restored = DwellTracker(fileURL: fileURL).load(currentAgents: [
            id: Agent(id: id, kind: .claude, status: .working, stateChangeSeq: 0)
        ])
        #expect(restored.isEmpty)
    }

    @Test("Restore guard: a status mismatch discards the entry")
    func statusMismatchDoesNotRestore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("dwell-state.json")

        let id = AgentID("w1:p1")
        let writer = DwellTracker(fileURL: fileURL)
        writer.update(agentId: id, status: .working, enteredAt: Date().addingTimeInterval(-600),
                      lastOutputAt: nil, occupantFingerprint: "claude", stateChangeSeq: 5)
        writer.save()

        let restored = DwellTracker(fileURL: fileURL).load(currentAgents: [
            id: Agent(id: id, kind: .claude, status: .blocked, stateChangeSeq: 5)
        ])
        #expect(restored.isEmpty)
    }
}
