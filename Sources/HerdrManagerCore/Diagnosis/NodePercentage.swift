/// Node 22.23.2 `--max-old-space-size-percentage`, from
/// `PerIsolateOptions::HandleMaxOldSpaceSizePercentage`.
///
/// An empty word is not checked: `CheckOptions` skips an empty field, so
/// `node --max-old-space-size-percentage '' script` still runs that file.
/// `--flag=` never reaches here. Every other word is `strtod` in the C
/// locale, and the whole word has to be consumed. `nan` (either case, an
/// optional sign, an optional parenthesized payload) passes the range
/// test because a NaN comparison is false, and the file runs. A finite
/// number runs only when the double is greater than 0 and at most 100.
/// `0x10` and `0x1p4` are 16. `inf`, `0`, `101`, and `50%` are not.
///
/// The double is not built digit by digit. The decision only changes at
/// 0 and at the midpoint between 100 and the next double (`100 + 2^-47`,
/// ties round back to 100). Those two compares are exact integer
/// compares. A word with more than 4096 significant digits inside either
/// gap is treated as running, so a value this walker cannot finish does
/// not hide a live agent. A word that is not a number still exits.
enum NodePercentage {
    /// True when this operand makes Node 22.23 exit before the script.
    static func rejects(_ value: String) -> Bool {
        if value.isEmpty { return false }
        guard let parsed = parse(value) else { return true }
        switch parsed {
        case .nan:
            return false
        case .infinity:
            return true
        case .decimal(let negative, let body, let floorLog, let truncated):
            return !decimalRuns(
                negative: negative,
                body: body,
                floorLog: floorLog,
                truncated: truncated
            )
        case .hex(let negative, let body, let power, let floorLog, let truncated):
            return !hexRuns(
                negative: negative,
                body: body,
                power: power,
                floorLog: floorLog,
                truncated: truncated
            )
        }
    }

    private enum Parsed {
        case nan
        case infinity
        /// `floorLog` is `floor(log10)` of a positive value. `body` drops
        /// leading zeros. The coefficient on that body is
        /// `floorLog - body.count + 1`.
        case decimal(
            negative: Bool,
            body: [UInt8],
            floorLog: Int64,
            truncated: Bool
        )
        /// `power` is the `2^power` on the integer of every hex digit.
        case hex(
            negative: Bool,
            body: [UInt8],
            power: Int64,
            floorLog: Int64,
            truncated: Bool
        )
    }

    private static let bodyLimit = 4096

    private static func parse(_ value: String) -> Parsed? {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count, isCSpace(scalars[index]) {
            index += 1
        }
        guard index < scalars.count else { return nil }
        var negative = false
        if scalars[index] == "+" || scalars[index] == "-" {
            negative = scalars[index] == "-"
            index += 1
            guard index < scalars.count else { return nil }
        }
        if hasWord(scalars, index: index, word: "nan") {
            return parseNan(scalars, index: index + 3)
        }
        if hasWord(scalars, index: index, word: "infinity") {
            return index + 8 == scalars.count ? .infinity : nil
        }
        if hasWord(scalars, index: index, word: "inf") {
            return index + 3 == scalars.count ? .infinity : nil
        }
        if index + 1 < scalars.count,
           scalars[index] == "0",
           scalars[index + 1] == "x" || scalars[index + 1] == "X" {
            return parseHex(scalars, index: index + 2, negative: negative)
        }
        return parseDecimal(scalars, index: index, negative: negative)
    }

    private static func parseNan(_ scalars: [Unicode.Scalar], index: Int) -> Parsed? {
        var index = index
        if index == scalars.count { return .nan }
        guard scalars[index] == "(" else { return nil }
        index += 1
        while index < scalars.count, isNChar(scalars[index]) {
            index += 1
        }
        guard index < scalars.count, scalars[index] == ")", index + 1 == scalars.count else {
            return nil
        }
        return .nan
    }

    private static func parseDecimal(
        _ scalars: [Unicode.Scalar],
        index: Int,
        negative: Bool
    ) -> Parsed? {
        var index = index
        var total = 0
        var leadingZeros = 0
        var sawDigit = false
        var sawDot = false
        var frac = 0
        var body: [UInt8] = []
        var truncated = false
        var sawNonZero = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ".", !sawDot {
                sawDot = true
                index += 1
                continue
            }
            guard let digit = asciiDigit(scalar) else { break }
            sawDigit = true
            total += 1
            if sawDot { frac += 1 }
            if !sawNonZero, digit == 0 {
                leadingZeros += 1
            } else {
                sawNonZero = true
                if body.count < bodyLimit {
                    body.append(digit)
                } else {
                    truncated = true
                }
            }
            index += 1
        }
        guard sawDigit else { return nil }
        var exp: Int64 = 0
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            guard let scanned = scanExponent(scalars, index: &index) else { return nil }
            exp = scanned
        }
        guard index == scalars.count else { return nil }
        let intDigits = total - frac
        var floorLog = satAdd(exp, Int64(intDigits))
        floorLog = satAdd(floorLog, -1)
        floorLog = satSub(floorLog, Int64(leadingZeros))
        return .decimal(
            negative: negative,
            body: body,
            floorLog: floorLog,
            truncated: truncated
        )
    }

    private static func parseHex(
        _ scalars: [Unicode.Scalar],
        index: Int,
        negative: Bool
    ) -> Parsed? {
        var index = index
        var total = 0
        var leadingZeros = 0
        var sawDigit = false
        var sawDot = false
        var frac = 0
        var body: [UInt8] = []
        var truncated = false
        var sawNonZero = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ".", !sawDot {
                sawDot = true
                index += 1
                continue
            }
            guard let digit = hexDigit(scalar) else { break }
            sawDigit = true
            total += 1
            if sawDot { frac += 1 }
            if !sawNonZero, digit == 0 {
                leadingZeros += 1
            } else {
                sawNonZero = true
                if body.count < bodyLimit {
                    body.append(digit)
                } else {
                    truncated = true
                }
            }
            index += 1
        }
        guard sawDigit else { return nil }
        var binExp: Int64 = 0
        if index < scalars.count, scalars[index] == "p" || scalars[index] == "P" {
            index += 1
            guard let scanned = scanExponent(scalars, index: &index) else { return nil }
            binExp = scanned
        }
        guard index == scalars.count else { return nil }
        let shift = satMul(4, Int64(frac))
        let power = satSub(binExp, shift)
        let significant = total - leadingZeros
        let topBits = hexTopBits(body.first ?? 0)
        let span = satMul(4, Int64(significant - 1))
        var floorLog = satAdd(power, span)
        floorLog = satAdd(floorLog, Int64(topBits - 1))
        return .hex(
            negative: negative,
            body: body,
            power: power,
            floorLog: floorLog,
            truncated: truncated
        )
    }

    /// Nil when `e` / `p` has no digit after it. That marker is then not
    /// part of the number, so the word is not fully consumed.
    private static func scanExponent(
        _ scalars: [Unicode.Scalar],
        index: inout Int
    ) -> Int64? {
        guard index < scalars.count else { return nil }
        var negative = false
        if scalars[index] == "+" || scalars[index] == "-" {
            negative = scalars[index] == "-"
            index += 1
        }
        guard index < scalars.count, asciiDigit(scalars[index]) != nil else { return nil }
        var exp: Int64 = 0
        var overflow = false
        while index < scalars.count, let digit = asciiDigit(scalars[index]) {
            index += 1
            if overflow { continue }
            let product = exp.multipliedReportingOverflow(by: 10)
            let sum = product.partialValue.addingReportingOverflow(Int64(digit))
            if product.overflow || sum.overflow {
                overflow = true
                continue
            }
            exp = sum.partialValue
        }
        if overflow {
            return negative ? Int64.min : Int64.max
        }
        if negative {
            return exp == 0 ? 0 : -exp
        }
        return exp
    }

    private static func decimalRuns(
        negative: Bool,
        body: [UInt8],
        floorLog: Int64,
        truncated: Bool
    ) -> Bool {
        if body.isEmpty { return false }
        if negative { return false }
        if floorLog >= 3 || floorLog <= -325 { return false }
        if floorLog != 2 && floorLog != -324 && floorLog != -323 { return true }
        // More digits than the gap needs. Keeping the process is the
        // direction that does not hide an agent Node actually ran.
        if truncated { return true }
        let magnitude = NodeWide.decimal(body)
        let coefficient = satAdd(satSub(floorLog, Int64(body.count)), 1)
        if floorLog == 2 {
            return !greaterThanHundred(magnitude, coefficient: coefficient)
        }
        return !underflowed(magnitude, coefficient: coefficient)
    }

    private static func hexRuns(
        negative: Bool,
        body: [UInt8],
        power: Int64,
        floorLog: Int64,
        truncated: Bool
    ) -> Bool {
        if body.isEmpty { return false }
        if negative { return false }
        if floorLog >= 7 || floorLog < -1075 { return false }
        if floorLog != 6 && floorLog != -1075 { return true }
        if truncated { return true }
        let magnitude = NodeWide.hex(body)
        if floorLog == 6 {
            return !hexGreaterThanHundred(magnitude, power: power)
        }
        return !hexUnderflowed(magnitude, power: power)
    }

    /// `N * 10^K > 100 + 2^-47`. A value on the midpoint rounds to 100.
    /// A negative coefficient that does not fit is a fraction far below
    /// 100, so it is not greater.
    private static func greaterThanHundred(_ magnitude: NodeWide, coefficient: Int64) -> Bool {
        let boundary = hundredBoundary()
        if coefficient >= 0 {
            guard let count = bounded(coefficient) else { return true }
            var left = magnitude
            left.multiply(byPow10: count)
            left.shiftLeft(47)
            if left.gaveUp { return false }
            return NodeWide.compare(left, boundary) > 0
        }
        guard let count = bounded(-coefficient) else { return false }
        var left = magnitude
        left.shiftLeft(47)
        var right = boundary
        right.multiply(byPow10: count)
        if left.gaveUp || right.gaveUp { return false }
        return NodeWide.compare(left, right) > 0
    }

    /// `N * 10^K <= 2^-1075`. That double is 0, and Node rejects it.
    /// A coefficient at least 0 is at least 1. One too negative to multiply
    /// is already 0.
    private static func underflowed(_ magnitude: NodeWide, coefficient: Int64) -> Bool {
        guard coefficient < 0, let digits = bounded(-coefficient) else {
            return coefficient < 0
        }
        var left = magnitude
        left.shiftLeft(1075)
        var right = NodeWide.one
        right.multiply(byPow10: digits)
        if left.gaveUp || right.gaveUp { return false }
        return NodeWide.compare(left, right) <= 0
    }

    /// `S * 2^E > 100 + 2^-47`.
    private static func hexGreaterThanHundred(_ magnitude: NodeWide, power: Int64) -> Bool {
        let boundary = hundredBoundary()
        let shift = satAdd(power, 47)
        if shift >= 0 {
            guard let bits = bounded(shift) else { return true }
            var left = magnitude
            left.shiftLeft(bits)
            if left.gaveUp { return false }
            return NodeWide.compare(left, boundary) > 0
        }
        // A shift this negative is far below 100.
        guard let bits = bounded(-shift) else { return false }
        var right = boundary
        right.shiftLeft(bits)
        if right.gaveUp { return false }
        return NodeWide.compare(magnitude, right) > 0
    }

    /// `S * 2^E <= 2^-1075`.
    private static func hexUnderflowed(_ magnitude: NodeWide, power: Int64) -> Bool {
        if power >= -1075 {
            let bits = power + 1075
            guard bits >= 0, let width = bounded(bits) else { return false }
            var left = magnitude
            left.shiftLeft(width)
            if left.gaveUp { return false }
            return NodeWide.compare(left, NodeWide.one) <= 0
        }
        guard let bits = bounded(-1075 - power) else { return true }
        let right = NodeWide.oneShifted(bits)
        if right.gaveUp { return false }
        return NodeWide.compare(magnitude, right) <= 0
    }

    /// `100 * 2^47 + 1`, the first integer strictly above the midpoint.
    private static func hundredBoundary() -> NodeWide {
        var boundary = NodeWide.decimal([1, 0, 0])
        boundary.shiftLeft(47)
        boundary.add(1)
        return boundary
    }

    /// The fuzzy-zone exponents fit in an `Int`. A saturated log does not.
    private static func bounded(_ value: Int64) -> Int? {
        if value < 0 || value > 20_000 { return nil }
        return Int(value)
    }

    private static func hasWord(
        _ scalars: [Unicode.Scalar],
        index: Int,
        word: String
    ) -> Bool {
        let expected = Array(word.unicodeScalars)
        guard index + expected.count <= scalars.count else { return false }
        for offset in expected.indices {
            if !sameLetter(scalars[index + offset], expected[offset]) { return false }
        }
        return true
    }

    private static func sameLetter(_ scalar: Unicode.Scalar, _ lower: Unicode.Scalar) -> Bool {
        if scalar == lower { return true }
        let value = scalar.value
        return value >= 65 && value <= 90 && value + 32 == lower.value
    }

    private static func isCSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 9, 10, 11, 12, 13, 32:
            return true
        default:
            return false
        }
    }

    private static func isNChar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 48 && value <= 57 { return true }
        if value >= 65 && value <= 90 { return true }
        if value >= 97 && value <= 122 { return true }
        return value == 95
    }

    private static func asciiDigit(_ scalar: Unicode.Scalar) -> UInt8? {
        let value = scalar.value
        guard value >= 48, value <= 57 else { return nil }
        return UInt8(value - 48)
    }

    private static func hexDigit(_ scalar: Unicode.Scalar) -> UInt8? {
        let value = scalar.value
        if value >= 48, value <= 57 { return UInt8(value - 48) }
        if value >= 97, value <= 102 { return UInt8(value - 87) }
        if value >= 65, value <= 70 { return UInt8(value - 55) }
        return nil
    }

    /// Bits in the top hex digit. `1` is one bit, `8`...`f` are four.
    private static func hexTopBits(_ digit: UInt8) -> Int {
        switch digit {
        case 1: return 1
        case 2, 3: return 2
        case 4, 5, 6, 7: return 3
        default: return 4
        }
    }

    private static func satAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let sum = lhs.addingReportingOverflow(rhs)
        if !sum.overflow { return sum.partialValue }
        return rhs >= 0 ? Int64.max : Int64.min
    }

    private static func satSub(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let difference = lhs.subtractingReportingOverflow(rhs)
        if !difference.overflow { return difference.partialValue }
        return rhs < 0 ? Int64.max : Int64.min
    }

    private static func satMul(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let product = lhs.multipliedReportingOverflow(by: rhs)
        if !product.overflow { return product.partialValue }
        let negative = (lhs < 0) != (rhs < 0)
        return negative ? Int64.min : Int64.max
    }
}

/// Base-2^32 integer. The percentage compare only multiplies by ten and
/// shifts. Past 8192 limbs the compare gives up, and the caller keeps the
/// process rather than calling a live agent a plain runtime.
private struct NodeWide {
    private var limbs: [UInt32]
    private(set) var gaveUp = false

    static let one = NodeWide(limbs: [1])

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    static func decimal(_ digits: [UInt8]) -> NodeWide {
        var value = NodeWide(limbs: [])
        for digit in digits {
            value.multiply(by: 10)
            value.add(UInt32(digit))
        }
        return value
    }

    static func hex(_ digits: [UInt8]) -> NodeWide {
        var value = NodeWide(limbs: [])
        for digit in digits {
            value.shiftLeft(4)
            value.add(UInt32(digit))
        }
        return value
    }

    static func oneShifted(_ bits: Int) -> NodeWide {
        var value = NodeWide.one
        value.shiftLeft(bits)
        return value
    }

    static func compare(_ lhs: NodeWide, _ rhs: NodeWide) -> Int {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count > rhs.limbs.count ? 1 : -1
        }
        var index = lhs.limbs.count
        while index > 0 {
            index -= 1
            if lhs.limbs[index] != rhs.limbs[index] {
                return lhs.limbs[index] > rhs.limbs[index] ? 1 : -1
            }
        }
        return 0
    }

    mutating func add(_ value: UInt32) {
        guard !gaveUp else { return }
        var carry = UInt64(value)
        var index = 0
        while carry > 0 {
            if index == limbs.count {
                limbs.append(UInt32(carry & 0xFFFF_FFFF))
                carry >>= 32
                continue
            }
            let sum = UInt64(limbs[index]) + carry
            limbs[index] = UInt32(sum & 0xFFFF_FFFF)
            carry = sum >> 32
            index += 1
        }
    }

    mutating func shiftLeft(_ bits: Int) {
        guard bits > 0, !limbs.isEmpty, !gaveUp else { return }
        let limbShift = bits / 32
        let bitShift = bits % 32
        if bitShift > 0 {
            var carry: UInt32 = 0
            for index in limbs.indices {
                let current = limbs[index]
                limbs[index] = (current << bitShift) | carry
                carry = current >> (32 - bitShift)
            }
            if carry != 0 { limbs.append(carry) }
        }
        if limbShift > 0 {
            guard limbs.count + limbShift <= 8192 else {
                gaveUp = true
                limbs = []
                return
            }
            limbs.insert(contentsOf: Array(repeating: 0, count: limbShift), at: 0)
        }
    }

    mutating func multiply(byPow10 count: Int) {
        guard count > 0, !gaveUp else { return }
        for _ in 0..<count {
            multiply(by: 10)
            if gaveUp { return }
        }
    }

    private mutating func multiply(by factor: UInt32) {
        guard !limbs.isEmpty, !gaveUp else { return }
        var carry: UInt64 = 0
        for index in limbs.indices {
            let product = UInt64(limbs[index]) * UInt64(factor) + carry
            limbs[index] = UInt32(product & 0xFFFF_FFFF)
            carry = product >> 32
        }
        if carry > 0 {
            guard limbs.count < 8192 else {
                gaveUp = true
                limbs = []
                return
            }
            limbs.append(UInt32(carry & 0xFFFF_FFFF))
        }
    }

    private mutating func normalize() {
        while limbs.last == 0 {
            limbs.removeLast()
        }
    }
}
