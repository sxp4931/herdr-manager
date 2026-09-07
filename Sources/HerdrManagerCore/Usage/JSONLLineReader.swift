import Foundation

/// Streams JSONL without loading a whole file, and without retaining a
/// single oversized line.
///
/// Usage records are small JSON objects. Transcript and tool payloads can
/// sit on one line and run to megabytes; those lines are skipped so a 30s
/// menu-bar token scan cannot pin RSS.
enum JSONLLineReader {
    static let maxLineBytes = 256 * 1024
    static let chunkSize = 64 * 1024

    static func forEachLine(in url: URL, body: (Int, Data) -> Void) {
        guard let stream = InputStream(url: url) else { return }
        stream.open()
        defer { stream.close() }

        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var pending = Data()
        pending.reserveCapacity(min(chunkSize, maxLineBytes))
        var start = 0
        var lineNumber = 0
        var skipping = false

        func compact() {
            guard start > 0 else { return }
            if start >= pending.count {
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.removeSubrange(0..<start)
            }
            start = 0
        }

        func emitLine(_ raw: Data) {
            var line = raw
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                body(lineNumber, line)
            }
            lineNumber += 1
        }

        func consume(eof: Bool) {
            while start < pending.count {
                if skipping {
                    if let newline = pending[start...].firstIndex(of: 0x0A) {
                        start = newline + 1
                        skipping = false
                        lineNumber += 1
                        continue
                    }
                    pending.removeAll(keepingCapacity: true)
                    start = 0
                    return
                }

                if let newline = pending[start...].firstIndex(of: 0x0A) {
                    let length = newline - start
                    if length > maxLineBytes {
                        start = newline + 1
                        lineNumber += 1
                        continue
                    }
                    emitLine(pending.subdata(in: start..<newline))
                    start = newline + 1
                    continue
                }

                if pending.count - start > maxLineBytes {
                    skipping = true
                    pending.removeAll(keepingCapacity: true)
                    start = 0
                }
                // Out of the loop, not out of the function: a file whose last
                // line carries no trailing newline still has to emit that line
                // once `eof` is known. Returning here dropped it.
                break
            }

            if eof, !skipping, start < pending.count {
                let length = pending.count - start
                if length <= maxLineBytes {
                    emitLine(pending.subdata(in: start..<pending.count))
                } else {
                    lineNumber += 1
                }
                start = pending.count
            }
        }

        while true {
            let n = stream.read(&chunk, maxLength: chunkSize)
            if n < 0 { return }
            if n == 0 {
                compact()
                consume(eof: true)
                return
            }
            compact()
            pending.append(contentsOf: chunk[0..<n])
            consume(eof: false)
        }
    }
}

/// Size-capped reads for tiny session sidecars (`summary.json`, `meta.json`,
/// `.cwd`). A multi-megabyte stand-in is ignored rather than loaded.
enum BoundedFileRead {
    static let maxSidecarBytes = 256 * 1024
    static let maxPathFileBytes = 8 * 1024
    /// Cursor stores compact session meta as hex in SQLite. A multi-megabyte
    /// stand-in must not be decoded into RSS during a 30s token scan.
    static let maxHexDecodedBytes = 8 * 1024
    /// Two hex chars per decoded byte. Copied into a Swift String only after
    /// the SQLite TEXT column is known to fit.
    static var maxHexEncodedBytes: Int { maxHexDecodedBytes * 2 }
    /// Cursor chat blobs are scanned as raw SQLite bytes. A 2 MB+ stand-in
    /// is refused rather than copied into RSS during a 30s token scan.
    static let maxCursorBlobBytes = 2_000_000

    /// True when a SQLite TEXT/BLOB column is non-empty and within `maxBytes`.
    static func sqliteColumnFits(_ byteCount: Int, maxBytes: Int) -> Bool {
        byteCount > 0 && byteCount <= maxBytes
    }

    static func dataFromHex(_ hex: String, maxDecodedBytes: Int = maxHexDecodedBytes) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2), !cleaned.isEmpty else { return nil }
        let decodedCount = cleaned.count / 2
        guard decodedCount <= maxDecodedBytes else { return nil }
        var data = Data(capacity: decodedCount)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func data(from url: URL, maxBytes: Int) -> Data? {
        guard maxBytes > 0 else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maxBytes else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else {
            return nil
        }
        return data
    }

    static func text(
        from url: URL,
        maxBytes: Int,
        encoding: String.Encoding = .utf8
    ) -> String? {
        guard let data = data(from: url, maxBytes: maxBytes) else { return nil }
        return String(data: data, encoding: encoding)
    }
}
