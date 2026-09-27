/// Whether Node 22.23's `convertStringToRegExp` throws for one
/// `--test-name-pattern` or `--test-skip-pattern` operand.
///
/// The wrapper is `^/(.*)/([a-z]*)$`: a match is `new RegExp(pattern, flags)`,
/// and anything else is `new RegExp(text)` with empty flags. The pattern
/// grammar is V8 12.4 (the engine in Node 22.23.2). Two throws are not
/// decided here, because each needs data this walker does not have:
/// a `v` flag's character-class grammar, and whether a `\p{…}` name is a
/// real Unicode property. A scalar above U+FFFF is a surrogate pair in
/// the legacy parser, so that pattern is not decided either.
enum NodeTestPattern {
    private static let quantifierInfinity = 2_147_483_647

    static func rejects(_ raw: String) -> Bool {
        let (pattern, flags) = parts(raw)
        if flagsReject(flags) { return true }
        if pattern.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
            return false
        }
        if flags.contains("v"), pattern.contains("[") {
            return false
        }
        var parser = Parser(
            text: pattern,
            unicode: flags.contains("u") || flags.contains("v")
        )
        return parser.fails()
    }

    /// The rightmost `/` whose tail is only `[a-z]`, when the text starts
    /// with `/`. `/a/b/g` is pattern `a/b` and flags `g`. `/foo/I` does
    /// not match, because `I` is not `[a-z]`, so the whole text is the
    /// pattern.
    private static func parts(_ raw: String) -> (pattern: String, flags: String) {
        let scalars = Array(raw.unicodeScalars)
        if scalars.count >= 2, scalars[0].value == 47 {
            var index = scalars.count - 1
            while index > 0 {
                if scalars[index].value == 47,
                   scalars[(index + 1)...].allSatisfy({ $0.value >= 97 && $0.value <= 122 }) {
                    return (
                        string(from: scalars[1..<index]),
                        string(from: scalars[(index + 1)...])
                    )
                }
                index -= 1
            }
        }
        return (raw, "")
    }

    private static func string(from scalars: ArraySlice<Unicode.Scalar>) -> String {
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        return text
    }

    /// `d g i m s u v y`, once each. `u` and `v` together throw. Any
    /// other letter throws. Empty flags are the default and run.
    private static func flagsReject(_ flags: String) -> Bool {
        let allowed: Set<Character> = ["d", "g", "i", "m", "s", "u", "v", "y"]
        var seen = Set<Character>()
        for character in flags {
            if !allowed.contains(character) || !seen.insert(character).inserted {
                return true
            }
        }
        return flags.contains("u") && flags.contains("v")
    }

    private struct Parser {
        private let scalars: [UInt32]
        private var index = 0
        private let unicode: Bool
        private var failed = false
        private var capturesStarted = 0
        private var names: [String] = []
        private var namedRefs: [String] = []
        private var stack: [GroupKind] = []
        private var captureCount = 0
        private var hasNamed = false
        private var scanned = false

        private enum GroupKind {
            case capture
            case group
            case lookahead
            case lookbehind
        }

        init(text: String, unicode: Bool) {
            scalars = text.unicodeScalars.map(\.value)
            self.unicode = unicode
        }

        mutating func fails() -> Bool {
            parse()
            if failed { return true }
            if unicode {
                if namedRefs.contains(where: { !names.contains($0) }) { return true }
            } else if !names.isEmpty {
                if namedRefs.contains(where: { !names.contains($0) }) { return true }
            }
            return Set(names).count != names.count
        }

        private var current: UInt32? {
            index < scalars.count ? scalars[index] : nil
        }

        private var nextScalar: UInt32? {
            index + 1 < scalars.count ? scalars[index + 1] : nil
        }

        private mutating func advance(_ distance: Int = 1) {
            index += distance
        }

        private func matches(_ value: UInt32?, _ literal: Unicode.Scalar) -> Bool {
            value == literal.value
        }

        private func isDigit(_ value: UInt32?) -> Bool {
            guard let value else { return false }
            return value >= 48 && value <= 57
        }

        private func isHex(_ value: UInt32?) -> Bool {
            guard let value else { return false }
            return isDigit(value)
                || (value >= 97 && value <= 102)
                || (value >= 65 && value <= 70)
        }

        private func hexValue(_ value: UInt32) -> UInt32 {
            if value <= 57 { return value - 48 }
            if value >= 97 { return value - 97 + 10 }
            return value - 65 + 10
        }

        private mutating func parse() {
            while !failed {
                let scalar = current
                var atom = false
                var kind: GroupKind?
                if scalar == nil {
                    if !stack.isEmpty { failed = true }
                    return
                }
                if matches(scalar, ")") {
                    guard let popped = stack.popLast() else {
                        failed = true
                        return
                    }
                    kind = popped
                    advance()
                    atom = true
                } else if matches(scalar, "|") {
                    advance()
                    continue
                } else if matches(scalar, "*") || matches(scalar, "+") || matches(scalar, "?") {
                    failed = true
                    return
                } else if matches(scalar, "^") || matches(scalar, "$") {
                    advance()
                    continue
                } else if matches(scalar, ".") {
                    advance()
                    atom = true
                } else if matches(scalar, "(") {
                    openParenthesis()
                    continue
                } else if matches(scalar, "[") {
                    characterClass()
                    if failed { return }
                    atom = true
                } else if matches(scalar, "\\") {
                    if atomEscape() == .assertion { continue }
                    if failed { return }
                    atom = true
                } else if matches(scalar, "{") {
                    let start = index
                    if let (lower, _) = interval() {
                        _ = lower
                        failed = true
                        return
                    }
                    index = start
                    if unicode {
                        failed = true
                        return
                    }
                    advance()
                    atom = true
                } else if unicode, matches(scalar, "}") || matches(scalar, "]") {
                    failed = true
                    return
                } else {
                    advance()
                    atom = true
                }
                if atom, !failed {
                    quantify(kind)
                }
            }
        }

        /// `^`, `$`, `\b`, and `\B` skip this: the quantifier is the
        /// next term, and a bare `*` is "Nothing to repeat". A
        /// lookbehind cannot take a quantifier in any mode. A
        /// lookahead cannot take one when `u` or `v` is set.
        private mutating func quantify(_ kind: GroupKind?) {
            let scalar = current
            if matches(scalar, "*") || matches(scalar, "+") || matches(scalar, "?") {
                advance()
            } else if matches(scalar, "{") {
                let start = index
                guard let parsed = interval() else {
                    if unicode { failed = true }
                    else { index = start }
                    return
                }
                if parsed.1 < parsed.0 {
                    failed = true
                    return
                }
            } else {
                return
            }
            if matches(current, "?") { advance() }
            if kind == .lookahead || kind == .lookbehind {
                if unicode || kind == .lookbehind { failed = true }
            }
        }

        /// `{digits}`, `{digits,}`, or `{digits,digits}`. Nil rewinds
        /// to the `{`. A value past `Int32.max` saturates there, which
        /// is V8's `kInfinity`, so `{2147483648,2147483647}` is not out
        /// of order and `{2147483648,1}` is.
        private mutating func interval() -> (Int, Int)? {
            let start = index
            advance()
            guard isDigit(current) else {
                index = start
                return nil
            }
            var lower = 0
            while isDigit(current) {
                let digit = Int(current! - 48)
                if lower > (NodeTestPattern.quantifierInfinity - digit) / 10 {
                    while isDigit(current) { advance() }
                    lower = NodeTestPattern.quantifierInfinity
                    break
                }
                lower = lower * 10 + digit
                advance()
            }
            if matches(current, "}") {
                advance()
                return (lower, lower)
            }
            guard matches(current, ",") else {
                index = start
                return nil
            }
            advance()
            if matches(current, "}") {
                advance()
                return (lower, NodeTestPattern.quantifierInfinity)
            }
            var upper = 0
            var sawDigit = false
            while isDigit(current) {
                sawDigit = true
                let digit = Int(current! - 48)
                if upper > (NodeTestPattern.quantifierInfinity - digit) / 10 {
                    while isDigit(current) { advance() }
                    upper = NodeTestPattern.quantifierInfinity
                    break
                }
                upper = upper * 10 + digit
                advance()
            }
            guard sawDigit, matches(current, "}") else {
                index = start
                return nil
            }
            advance()
            return (lower, upper)
        }

        private mutating func openParenthesis() {
            advance()
            guard matches(current, "?") else {
                capturesStarted += 1
                stack.append(.capture)
                return
            }
            let marker = nextScalar
            if matches(marker, ":") {
                advance(2)
                stack.append(.group)
                return
            }
            if matches(marker, "=") || matches(marker, "!") {
                advance(2)
                stack.append(.lookahead)
                return
            }
            if matches(marker, "<") {
                advance()
                let after = nextScalar
                if matches(after, "=") || matches(after, "!") {
                    advance(2)
                    stack.append(.lookbehind)
                    return
                }
                advance()
                if let name = captureName() {
                    names.append(name)
                }
                if failed { return }
                capturesStarted += 1
                stack.append(.capture)
                return
            }
            failed = true
        }

        /// `(?<name>`. `\u` escapes are decoded, including in a legacy
        /// pattern: the name production forces Unicode. A non-ASCII
        /// scalar is accepted, so a name V8's ID_Start set would refuse
        /// is not this check. `>` ends the name and is consumed.
        private mutating func captureName() -> String? {
            var units: [UInt32] = []
            var atStart = true
            while !failed {
                guard let scalar = current else {
                    failed = true
                    return nil
                }
                let decoded: UInt32
                if matches(scalar, "\\"), matches(nextScalar, "u") {
                    advance(2)
                    guard let value = unicodeEscape(forceBraces: true) else {
                        failed = true
                        return nil
                    }
                    decoded = value
                } else if matches(scalar, "\\") {
                    failed = true
                    return nil
                } else {
                    decoded = scalar
                    advance()
                }
                if atStart {
                    guard identifierStart(decoded) else {
                        failed = true
                        return nil
                    }
                    units.append(decoded)
                    atStart = false
                } else if decoded == Unicode.Scalar(">").value {
                    break
                } else if identifierPart(decoded) {
                    units.append(decoded)
                } else {
                    failed = true
                    return nil
                }
            }
            if units.contains(where: { $0 > 127 }) {
                return "U:" + units.map(String.init).joined(separator: ",")
            }
            var text = ""
            for unit in units {
                guard let scalar = Unicode.Scalar(unit) else { return nil }
                text.unicodeScalars.append(scalar)
            }
            return text
        }

        private func identifierStart(_ value: UInt32) -> Bool {
            if value > 127 { return true }
            if (value >= 65 && value <= 90) || (value >= 97 && value <= 122) { return true }
            return value == Unicode.Scalar("$").value || value == Unicode.Scalar("_").value
        }

        private func identifierPart(_ value: UInt32) -> Bool {
            identifierStart(value) || isDigit(value)
        }

        private mutating func characterClass() {
            advance()
            if matches(current, "^") { advance() }
            if matches(current, "]") {
                advance()
                return
            }
            if current == nil {
                failed = true
                return
            }
            classRanges()
            if failed { return }
            guard matches(current, "]") else {
                failed = true
                return
            }
            advance()
        }

        /// `]` that is not the first body character closes the class.
        /// `[]` is empty in both modes. A following `]` is a literal
        /// only when Unicode mode is off.
        private mutating func classRanges() {
            while !failed, let scalar = current, !matches(scalar, "]") {
                let (classEscape, first) = classAtom()
                if failed { return }
                guard matches(current, "-") else { continue }
                advance()
                if current == nil || matches(current, "]") { break }
                let (classEscape2, second) = classAtom()
                if failed { return }
                if classEscape || classEscape2 {
                    if unicode { failed = true }
                    continue
                }
                if first > second { failed = true }
            }
        }

        /// `(isClassEscape, codePoint)`. `\b` inside a class is
        /// backspace. Unicode `\-` inside a class is a dash; outside a
        /// class that escape is not a syntax character and throws.
        private mutating func classAtom() -> (Bool, UInt32) {
            guard matches(current, "\\") else {
                guard let scalar = current else {
                    failed = true
                    return (false, 0)
                }
                advance()
                return (false, scalar)
            }
            let following = nextScalar
            if matches(following, "b") {
                advance(2)
                return (false, 8)
            }
            if unicode, matches(following, "-") {
                advance(2)
                return (false, Unicode.Scalar("-").value)
            }
            if following == nil {
                failed = true
                return (false, 0)
            }
            if matches(following, "d") || matches(following, "D")
                || matches(following, "s") || matches(following, "S")
                || matches(following, "w") || matches(following, "W") {
                advance(2)
                return (true, 0)
            }
            if unicode, matches(following, "p") || matches(following, "P") {
                advance(2)
                if !propertyName() { failed = true }
                return (true, 0)
            }
            return (false, characterEscape(inClass: true))
        }

        /// `{…}` after `\p` or `\P`. The property database is not
        /// consulted: an unknown name does not throw here.
        private mutating func propertyName() -> Bool {
            guard matches(current, "{") else { return false }
            advance()
            if matches(current, "}") || current == nil { return false }
            while let scalar = current, !matches(scalar, "}") {
                advance()
            }
            guard matches(current, "}") else { return false }
            advance()
            return true
        }

        private enum EscapeKind {
            case atom
            case assertion
        }

        private mutating func atomEscape() -> EscapeKind {
            guard let following = nextScalar else {
                failed = true
                return .atom
            }
            if following >= 49 && following <= 57 {
                if backreference() { return .atom }
                if unicode {
                    failed = true
                    return .atom
                }
                if following == Unicode.Scalar("8").value || following == Unicode.Scalar("9").value {
                    advance(2)
                    return .atom
                }
                advance()
                octal()
                return .atom
            }
            if matches(following, "0") {
                advance()
                if unicode, let digit = nextScalar, isDigit(digit) {
                    failed = true
                    return .atom
                }
                octal()
                return .atom
            }
            if matches(following, "b") || matches(following, "B") {
                advance(2)
                return .assertion
            }
            if matches(following, "d") || matches(following, "D")
                || matches(following, "s") || matches(following, "S")
                || matches(following, "w") || matches(following, "W") {
                advance(2)
                return .atom
            }
            if matches(following, "p") || matches(following, "P") {
                if unicode {
                    advance(2)
                    if !propertyName() { failed = true }
                    return .atom
                }
                advance(2)
                return .atom
            }
            if matches(following, "k") {
                namedOrIdentity()
                return .atom
            }
            _ = characterEscape(inClass: false)
            return .atom
        }

        /// The longest decimal is the backreference. It counts only
        /// when that number is at most the capturing groups in the
        /// whole pattern, so `\1(a)` is a forward reference and
        /// `(a)\12` is not `\1` plus `2`. A miss rewinds to the
        /// backslash.
        private mutating func backreference() -> Bool {
            let start = index
            guard let following = nextScalar else { return false }
            var value = Int(following - 48)
            advance(2)
            while isDigit(current) {
                let digit = Int(current! - 48)
                let next = value * 10 + digit
                if next > 65_535 {
                    index = start
                    return false
                }
                value = next
                advance()
            }
            if value > totalCaptures() {
                index = start
                return false
            }
            return true
        }

        private mutating func totalCaptures() -> Int {
            if !scanned { scan() }
            return captureCount
        }

        private mutating func namedCapturesExist() -> Bool {
            if !scanned { scan() }
            return hasNamed
        }

        /// Groups, and whether any of them is named. Character classes
        /// are skipped. `(?:` and `(?<=` are not captures. `(?<name>` is.
        private mutating func scan() {
            var cursor = 0
            var captures = 0
            var named = false
            while cursor < scalars.count {
                let scalar = scalars[cursor]
                cursor += 1
                if scalar == Unicode.Scalar("\\").value {
                    cursor += 1
                    continue
                }
                if scalar == Unicode.Scalar("[").value {
                    while cursor < scalars.count {
                        let body = scalars[cursor]
                        cursor += 1
                        if body == Unicode.Scalar("\\").value {
                            cursor += 1
                        } else if body == Unicode.Scalar("]").value {
                            break
                        }
                    }
                    continue
                }
                if scalar == Unicode.Scalar("(").value {
                    if cursor < scalars.count, scalars[cursor] == Unicode.Scalar("?").value {
                        cursor += 1
                        if cursor >= scalars.count
                            || scalars[cursor] != Unicode.Scalar("<").value {
                            continue
                        }
                        cursor += 1
                        if cursor < scalars.count,
                           scalars[cursor] == Unicode.Scalar("=").value
                            || scalars[cursor] == Unicode.Scalar("!").value {
                            continue
                        }
                        named = true
                    }
                    captures += 1
                }
            }
            captureCount = captures
            hasNamed = named
            scanned = true
        }

        private mutating func octal() {
            guard let scalar = current else {
                failed = true
                return
            }
            var value = scalar - 48
            advance()
            if let digit = current, digit >= 48, digit <= 55 {
                value = value * 8 + (digit - 48)
                advance()
                if value < 32, let third = current, third >= 48, third <= 55 {
                    advance()
                }
            }
        }

        /// `\k<name>` when Unicode mode is on, or when the pattern has
        /// a named group. Otherwise `\k` is an identity escape.
        private mutating func namedOrIdentity() {
            if unicode || namedCapturesExist() {
                advance(2)
                guard matches(current, "<") else {
                    failed = true
                    return
                }
                advance()
                if let name = captureName() {
                    namedRefs.append(name)
                }
                return
            }
            advance(2)
        }

        /// The character an escape produces. An invalid `\c` in legacy
        /// mode is a literal backslash and the `c` stays for the next
        /// term: V8 does not consume the letter.
        private mutating func characterEscape(inClass: Bool) -> UInt32 {
            advance()
            guard let scalar = current else {
                failed = true
                return 0
            }
            if matches(scalar, "f") { advance(); return 12 }
            if matches(scalar, "n") { advance(); return 10 }
            if matches(scalar, "r") { advance(); return 13 }
            if matches(scalar, "t") { advance(); return 9 }
            if matches(scalar, "v") { advance(); return 11 }
            if matches(scalar, "c") {
                if let letter = nextScalar {
                    let folded = letter & ~UInt32(65 ^ 97)
                    if folded >= 65, folded <= 90 {
                        advance(2)
                        return letter & 0x1F
                    }
                    if !unicode, inClass,
                       isDigit(letter) || letter == Unicode.Scalar("_").value {
                        advance(2)
                        return letter & 0x1F
                    }
                }
                if unicode {
                    failed = true
                    return 0
                }
                return Unicode.Scalar("\\").value
            }
            if matches(scalar, "0") {
                if let digit = nextScalar, isDigit(digit) {
                    if unicode {
                        failed = true
                        return 0
                    }
                    octal()
                    return 0
                }
                advance()
                return 0
            }
            if scalar >= 49 && scalar <= 55 {
                if unicode {
                    failed = true
                    return 0
                }
                octal()
                return 0
            }
            if matches(scalar, "x") {
                advance()
                if let value = hexEscape(length: 2) { return value }
                if unicode {
                    failed = true
                    return 0
                }
                return Unicode.Scalar("x").value
            }
            if matches(scalar, "u") {
                advance()
                if let value = unicodeEscape(forceBraces: false) { return value }
                if unicode {
                    failed = true
                    return 0
                }
                return Unicode.Scalar("u").value
            }
            if unicode {
                if !syntaxOrSlash(scalar) {
                    failed = true
                    return 0
                }
                advance()
                return scalar
            }
            advance()
            if matches(scalar, "k"), namedCapturesExist() {
                failed = true
                return 0
            }
            return scalar
        }

        /// `\u{hex}` only in Unicode mode, otherwise four hex digits.
        /// `forceBraces` is the capture-name production, which accepts
        /// braces even in a legacy pattern.
        private mutating func unicodeEscape(forceBraces: Bool) -> UInt32? {
            if (unicode || forceBraces), matches(current, "{") {
                let start = index
                advance()
                if let value = unlimitedHex(maxValue: 0x10FFFF), matches(current, "}") {
                    advance()
                    return value
                }
                index = start
                if forceBraces { return nil }
            }
            return hexEscape(length: 4)
        }

        private mutating func hexEscape(length: Int) -> UInt32? {
            let start = index
            var value: UInt32 = 0
            for _ in 0..<length {
                guard let scalar = current, isHex(scalar) else {
                    index = start
                    return nil
                }
                value = value * 16 + hexValue(scalar)
                advance()
            }
            return value
        }

        private mutating func unlimitedHex(maxValue: UInt32) -> UInt32? {
            guard isHex(current) else { return nil }
            var value: UInt32 = 0
            while let scalar = current, isHex(scalar) {
                let digit = hexValue(scalar)
                if value > (maxValue - digit) / 16 {
                    while let extra = current, isHex(extra) { advance() }
                    return nil
                }
                value = value * 16 + digit
                advance()
            }
            return value
        }

        private func syntaxOrSlash(_ value: UInt32) -> Bool {
            switch value {
            case Unicode.Scalar("^").value, Unicode.Scalar("$").value,
                 Unicode.Scalar("\\").value, Unicode.Scalar(".").value,
                 Unicode.Scalar("*").value, Unicode.Scalar("+").value,
                 Unicode.Scalar("?").value, Unicode.Scalar("(").value,
                 Unicode.Scalar(")").value, Unicode.Scalar("[").value,
                 Unicode.Scalar("]").value, Unicode.Scalar("{").value,
                 Unicode.Scalar("}").value, Unicode.Scalar("|").value,
                 Unicode.Scalar("/").value:
                return true
            default:
                return false
            }
        }
    }
}
