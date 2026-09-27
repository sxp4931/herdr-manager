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
