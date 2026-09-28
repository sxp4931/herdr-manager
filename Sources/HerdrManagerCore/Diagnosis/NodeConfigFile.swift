import Foundation

/// Node 22.23.2's `--experimental-config-file` and
/// `--experimental-default-config-file`.
///
/// `GetDataFromArgs` picks the path before the option parser runs, and
/// `Init` reads that file before `--run` and before the positional. A
/// missing file, a directory, JSON that is not an object, and a
/// `nodeOptions` entry the env allowlist rejects all exit, so the
/// package script and a file written first do not run. `watch: true`
/// and a non-empty `watch-path` exit too: `Implies` turns the path into
/// `--watch`, and `CheckOptions` then runs on the config's own argv,
/// which has no script. A later `--no-watch` on the command line does
/// not clear it. A valid file's options are the words Node inserts in
/// front of the real argv.
///
/// The names are `MapEnvOptionsFlagInputType` at tag v22.23.2: every
/// option registered with `kAllowedInEnvvar`. An alias (`report-directory`,
/// `experimental-permission`) is not in that map. A V8 flag and a no-op
/// are in the map and still invalid content. `enable-fips` and
/// `force-fips` are booleans Node rejects on a build without FIPS; a
/// FIPS build would run them, which is the same limit as the command
/// line. A file larger than 1 MiB is not read, so the positional stays
/// the candidate instead of stalling the sample on a log Node was
/// pointed at.
enum NodeConfigFile {
    enum Effect: Equatable {
        /// No config path was selected.
        case absent
        /// Node exits before the user program.
        case exits
        /// A file Node accepts. These words are applied before the CLI.
        /// Empty when the file names nothing the script walk has to see.
        case flags([String])
    }

    static func effect(argv: [String], cwd: String?) -> Effect {
        guard let token = selectedPath(argv) else { return .absent }
        guard let path = resolved(token, cwd: cwd) else { return .exits }
        switch load(path) {
        case .exits:
            return .exits
        case .skip:
            return .flags([])
        case .data(let data):
            guard let object = document(from: data) else { return .exits }
            return translated(object)
        }
    }

    /// The first path `GetDataFromArgs` returns.
    ///
    /// `--experimental-config-file PATH` and the `=` form win, including
    /// an empty `=` and a following word that starts with `-`: that word
    /// is the filename, not the next option. A later
    /// `--experimental-config-file=good.json` is not consulted once an
    /// earlier word was returned. The flag with no following word does
    /// not select a path. `--experimental-default-config-file`, including
    /// `=true` and an empty `=`, is `node.config.json` when no explicit
    /// path was returned. `--no-experimental-default-config-file` does
    /// not start with that name.
    private static func selectedPath(_ argv: [String]) -> String? {
        let flag = "--experimental-config-file"
        let defaultFlag = "--experimental-default-config-file"
        var hasDefault = false
        var index = 0
        while index < argv.count {
            let arg = argv[index]
            if arg == flag {
                if index + 1 < argv.count {
                    return argv[index + 1]
                }
            } else if arg.hasPrefix(flag) {
                let rest = arg.dropFirst(flag.count)
                if rest.hasPrefix("=") {
                    return String(rest.dropFirst())
                }
            } else if arg == defaultFlag || arg.hasPrefix(defaultFlag) {
                hasDefault = true
            }
            index += 1
        }
        return hasDefault ? "node.config.json" : nil
    }

    /// Absolute, or joined to an absolute process cwd. A backslash is a
    /// Windows path and is not opened. Without a cwd a relative name,
    /// including the default `node.config.json`, is not this process's
    /// file.
    private static func resolved(_ token: String, cwd: String?) -> String? {
        if token.hasPrefix("/") { return token }
        if token.contains("\\") { return nil }
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        let prefix = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if token.isEmpty { return prefix + "/" }
        return prefix + "/" + token
    }

    private enum Load {
        case data(Data)
        case exits
        /// Larger than 1 MiB. The positional stays the candidate.
        case skip
    }

    private static func load(_ path: String) -> Load {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .exits
        }
        if isDirectory.boolValue { return .exits }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0 else {
            return .exits
        }
        if size.int64Value > 1_048_576 { return .skip }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .exits
        }
        return .data(data)
    }

    /// An object, after the two leniencies simdjson has that
    /// `JSONSerialization` does not: a leading BOM, and one trailing
    /// comma before `}` or `]`. Anything else Node rejects, including a
    /// comment and a root that is not an object, is nil.
    private static func document(from data: Data) -> [String: Any]? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        if let object = jsonObject(text) {
            return object
        }
        let loosened = stripTrailingCommas(text)
        guard loosened != text else { return nil }
        return jsonObject(loosened)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Drop a comma that has only whitespace between it and `}` or `]`,
    /// outside a string. A comma inside a title stays.
    private static func stripTrailingCommas(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }
            if character == "," {
                var look = index + 1
                while look < characters.count, jsonSpace(characters[look]) {
                    look += 1
                }
                if look < characters.count,
                   characters[look] == Character("}") || characters[look] == Character("]") {
                    index += 1
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func jsonSpace(_ character: Character) -> Bool {
        switch character {
        case " ", "\n", "\r", "\t":
            return true
        default:
            return false
        }
    }

    private static func translated(_ object: [String: Any]) -> Effect {
        guard let options = object["nodeOptions"] else { return .flags([]) }
        guard let fields = options as? [String: Any] else { return .exits }
        var emitted: [String] = []
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            guard let kind = kind(of: key) else { return .exits }
            switch kind {
            case .rejected:
                return .exits
            case .boolean:
                guard let on = jsonBool(value) else { return .exits }
                if !on { continue }
                // `CheckOptions` sees `--watch` before the user's script.
                // FIPS exits on this build, and the command line already
                // treats those two flags as not a script.
                if key == "watch" || key == "enable-fips" || key == "force-fips" {
                    return .exits
                }
                emitted.append("--" + key)
            case .string:
                guard let text = jsonString(value) else { return .exits }
                if stringBreaksNodeOptions(text) { return .exits }
                emitted.append("--\(key)=\(text)")
            case .list:
                guard let items = jsonStringList(value) else { return .exits }
                for text in items {
                    if stringBreaksNodeOptions(text) { return .exits }
                    // A path implies `--watch` before the user's script.
                    if key == "watch-path" { return .exits }
                    emitted.append("--\(key)=\(text)")
                }
            case .integer:
                guard let number = jsonSigned(value) else { return .exits }
                emitted.append("--\(key)=\(number)")
            case .uinteger:
                guard let number = jsonUnsigned(value) else { return .exits }
                emitted.append("--\(key)=\(number)")
            }
        }
        return .flags(emitted)
    }

    /// A space splits the flag. A quote starts a string the config
    /// writer never closes. An empty value is `--flag=` with no
    /// argument. Node exits on all three before the program runs.
    private static func stringBreaksNodeOptions(_ text: String) -> Bool {
        text.isEmpty || text.contains(" ") || text.contains("\"")
    }

    private enum Kind {
        case boolean
        case string
        case list
        case integer
        case uinteger
        case rejected
    }

    private static func kind(of key: String) -> Kind? {
        if booleans.contains(key) { return .boolean }
        if strings.contains(key) { return .string }
        if lists.contains(key) { return .list }
        if integers.contains(key) { return .integer }
        if uintegers.contains(key) { return .uinteger }
        if rejected.contains(key) { return .rejected }
        return nil
    }

    /// JSON `true` and `false` only. `1` is not a boolean, which is the
    /// check that rejects `"watch": 1`.
    private static func jsonBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func jsonString(_ value: Any) -> String? {
        value as? String
    }

    /// A string list accepts one string or an array of strings.
    private static func jsonStringList(_ value: Any) -> [String]? {
        if let text = value as? String { return [text] }
        guard let items = value as? [Any] else { return nil }
        var strings: [String] = []
        for item in items {
            guard let text = item as? String else { return nil }
            strings.append(text)
        }
        return strings
    }

    /// An integer JSON number. A boolean is not one. A magnitude that
    /// is not a whole number is not one (`4.5`). `JSONSerialization`
    /// does not keep the spelling, so an integral float token (`4.0`,
    /// `1e1`) is the same value as an integer and is kept; Node rejects
    /// that spelling.
    private static func jsonSigned(_ value: Any) -> Int64? {
        guard let number = integerNumber(value) else { return nil }
        let type = String(cString: number.objCType)
        switch type {
        case "c", "s", "i", "l", "q", "C", "S", "I", "L":
            return number.int64Value
        case "Q":
            let unsigned = number.uint64Value
            guard unsigned <= UInt64(Int64.max) else { return nil }
            return Int64(unsigned)
        case "d", "f":
            let magnitude = number.doubleValue
            // `Int64.max` is not a Double. `2^63` does not fit.
            guard magnitude.isFinite, magnitude.rounded() == magnitude,
                  magnitude >= -0x1p63, magnitude < 0x1p63 else {
                return nil
            }
            return Int64(magnitude)
        default:
            return nil
        }
    }

    private static func jsonUnsigned(_ value: Any) -> UInt64? {
        guard let number = integerNumber(value) else { return nil }
        if number.compare(NSNumber(value: 0)) == .orderedAscending { return nil }
        let type = String(cString: number.objCType)
        switch type {
        case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
            return number.uint64Value
        case "d", "f":
            let magnitude = number.doubleValue
            // `UInt64.max` rounds up to `2^64`, which does not fit.
            guard magnitude.isFinite, magnitude >= 0, magnitude.rounded() == magnitude,
                  magnitude < 0x1p64 else {
                return nil
            }
            return UInt64(magnitude)
        default:
            return nil
        }
    }

    private static func integerNumber(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number
    }

    private static func names(_ text: String) -> Set<String> {
        var values: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            values.insert(String(line))
        }
        return values
    }

    private static let booleans: Set<String> = names("""
    addons
    allow-addons
    allow-child-process
    allow-wasi
    allow-worker
    cpu-prof
    debug-arraybuffer-allocations
    deprecation
    disable-sigusr1
    disable-wasm-trap-handler
    enable-fips
    enable-source-maps
    entry-url
    experimental-addon-modules
    experimental-async-context-frame
    experimental-detect-module
    experimental-eventsource
    experimental-fetch
    experimental-global-customevent
    experimental-global-navigator
    experimental-global-webcrypto
    experimental-import-meta-resolve
    experimental-print-required-tla
    experimental-repl-await
    experimental-require-module
    experimental-shadow-realm
    experimental-sqlite
    experimental-strip-types
    experimental-transform-types
    experimental-vm-modules
    experimental-websocket
    experimental-webstorage
    extra-info-on-fatal-exception
    force-async-hooks-checks
    force-context-aware
    force-fips
    force-node-api-uncaught-exceptions-policy
    frozen-intrinsics
    global-search-paths
    heap-prof
    insecure-http-parser
    inspect
    inspect-brk
    inspect-wait
    network-family-autoselection
    node-snapshot
    openssl-legacy-provider
    openssl-shared-config
    pending-deprecation
    permission
    preserve-symlinks
    preserve-symlinks-main
    report-compact
    report-exclude-env
    report-exclude-network
    report-on-fatalerror
    report-on-signal
    report-uncaught-exception
    test-only
    throw-deprecation
    tls-max-v1.2
    tls-max-v1.3
    tls-min-v1.0
    tls-min-v1.1
    tls-min-v1.2
    tls-min-v1.3
    trace-atomics-wait
    trace-deprecation
    trace-env
    trace-env-js-stack
    trace-env-native-stack
    trace-exit
    trace-promises
    trace-sigint
    trace-sync-io
    trace-tls
    trace-uncaught
    trace-warnings
    track-heap-objects
    use-bundled-ca
    use-env-proxy
    use-openssl-ca
    use-system-ca
    verify-base-objects
    warnings
    watch
    watch-preserve-output
    zero-fill-buffers
    """)

    private static let strings: Set<String> = names("""
    cpu-prof-dir
    cpu-prof-name
    diagnostic-dir
    disable-proto
    dns-result-order
    experimental-default-type
    heap-prof-dir
    heap-prof-name
    heapsnapshot-signal
    icu-data-dir
    input-type
    inspect-publish-uid
    localstorage-file
    max-old-space-size-percentage
    openssl-config
    redirect-warnings
    report-dir
    report-filename
    report-signal
    snapshot-blob
    test-shard
    title
    tls-cipher-list
    tls-keylog
    trace-event-categories
    trace-event-file-pattern
    trace-require-module
    unhandled-rejections
    use-largepages
    watch-kill-signal
    """)

    private static let lists: Set<String> = names("""
    allow-fs-read
    allow-fs-write
    conditions
    disable-warning
    experimental-loader
    import
    require
    test-coverage-exclude
    test-coverage-include
    test-name-pattern
    test-reporter
    test-reporter-destination
    test-skip-pattern
    watch-path
    """)

    private static let integers: Set<String> = names("""
    heapsnapshot-near-heap-limit
    secure-heap
    secure-heap-min
    stack-trace-limit
    v8-pool-size
    """)

    private static let uintegers: Set<String> = names("""
    cpu-prof-interval
    heap-prof-interval
    inspect-port
    max-http-header-size
    network-family-autoselection-attempt-timeout
    test-coverage-branches
    test-coverage-functions
    test-coverage-lines
    """)

    private static let rejected: Set<String> = names("""
    abort-on-uncaught-exception
    disallow-code-generation-from-strings
    enable-etw-stack-walking
    experimental-abortcontroller
    experimental-json-modules
    experimental-modules
    experimental-report
    experimental-specifier-resolution
    experimental-top-level-await
    experimental-wasi-unstable-preview1
    experimental-wasm-modules
    experimental-worker
    expose-gc
    http-parser
    huge-max-old-generation-size
    interpreted-frames-native-stack
    jitless
    max-old-space-size
    max-semi-space-size
    napi-modules
    node-memory-debug
    perf-basic-prof
    perf-basic-prof-only-functions
    perf-prof
    perf-prof-unwinding-info
    """)
}
