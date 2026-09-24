import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Where a later read of an append-only JSONL log picks up.
struct JSONLResumePoint: Equatable, Sendable {
    /// Byte offset just past the last newline read.
    var offset: UInt64
    /// Line number of the line that starts at `offset`.
    var lineNumber: Int

    static let start = JSONLResumePoint(offset: 0, lineNumber: 0)
}

struct JSONLReadResult: Equatable, Sendable {
    var resumePoint: JSONLResumePoint
    /// Bytes read from the file, which starts at the resume point.
    var bytesRead: UInt64
}

/// Streams JSONL without loading a whole file, and without retaining a
/// single oversized line.
///
/// Usage records are small JSON objects. Transcript and tool payloads can
/// sit on one line and run to megabytes; those lines are skipped so a 30s
/// menu-bar token scan cannot pin RSS.
enum JSONLLineReader {
    static let maxLineBytes = 256 * 1024
    static let chunkSize = 64 * 1024
    /// Bytes before a resume point that must be unchanged to resume there.
    static let signatureLength = 64

    static func forEachLine(in url: URL, body: (Int, Data) -> Void) {
        forEachLine(in: url, resumingAt: .start) { lineNumber, line, _ in
            body(lineNumber, line)
        }
    }

    /// Stream lines from `start` to the end of the file. `terminated` is
    /// false only for a last line with no newline yet: a live log's writer
    /// may still be adding to it, so the returned resume point stays before
    /// it and the next read delivers it again.
    ///
    /// - Returns: Where the next read of this file can resume, or nil when
    ///   the file cannot be opened, positioned, or read.
    @discardableResult
    static func forEachLine(
        in url: URL,
        resumingAt start: JSONLResumePoint,
        body: (_ lineNumber: Int, _ line: Data, _ terminated: Bool) -> Void
    ) -> JSONLReadResult? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if start.offset > 0 {
            guard start.offset <= UInt64(Int64.max),
                  lseek(fd, off_t(start.offset), SEEK_SET) >= 0 else {
                return nil
            }
        }

        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var pending = Data()
        pending.reserveCapacity(min(chunkSize, maxLineBytes))
        /// File offset of `pending`'s first byte.
        var pendingOffset = start.offset
        var cursor = 0
        var lineNumber = start.lineNumber
        var skipping = false
        var resume = start
        var bytesRead: UInt64 = 0

        func compact() {
            guard cursor > 0 else { return }
            pendingOffset += UInt64(cursor)
            if cursor >= pending.count {
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.removeSubrange(0..<cursor)
            }
            cursor = 0
        }

        func discardPending() {
            pendingOffset += UInt64(pending.count)
            pending.removeAll(keepingCapacity: true)
            cursor = 0
        }

        func finishLine(endingAt newline: Int) {
            cursor = newline + 1
            lineNumber += 1
            resume = JSONLResumePoint(
                offset: pendingOffset + UInt64(cursor),
                lineNumber: lineNumber
            )
        }

        func emitLine(_ raw: Data, terminated: Bool) {
            var line = raw
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                body(lineNumber, line, terminated)
            }
        }

        func consume(eof: Bool) {
            while cursor < pending.count {
                if skipping {
                    if let newline = pending[cursor...].firstIndex(of: 0x0A) {
                        skipping = false
                        finishLine(endingAt: newline)
                        continue
                    }
                    discardPending()
                    return
                }

                if let newline = pending[cursor...].firstIndex(of: 0x0A) {
                    if newline - cursor <= maxLineBytes {
                        emitLine(pending.subdata(in: cursor..<newline), terminated: true)
                    }
                    finishLine(endingAt: newline)
                    continue
                }

                if pending.count - cursor > maxLineBytes {
                    skipping = true
                    discardPending()
                }
                // Out of the loop, not out of the function: a file whose last
                // line carries no trailing newline still has to emit that line
                // once `eof` is known. Returning here dropped it.
                break
            }

            if eof, !skipping, cursor < pending.count {
                if pending.count - cursor <= maxLineBytes {
                    emitLine(pending.subdata(in: cursor..<pending.count), terminated: false)
                }
                lineNumber += 1
                cursor = pending.count
            }
        }

        while true {
            let n = read(fd, &chunk, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 {
                compact()
                consume(eof: true)
                return JSONLReadResult(resumePoint: resume, bytesRead: bytesRead)
            }
            bytesRead += UInt64(n)
            compact()
            pending.append(contentsOf: chunk[0..<n])
            consume(eof: false)
        }
    }

    /// Up to `signatureLength` bytes ending at `offset`. A read resumes at
    /// `offset` only while these bytes are unchanged, so a log that was
    /// rewritten or replaced in place is read again from the start.
    static func signature(of url: URL, endingAt offset: UInt64) -> Data? {
        guard offset > 0 else { return Data() }
        guard offset <= UInt64(Int64.max) else { return nil }
        let count = Int(min(UInt64(signatureLength), offset))
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: count)
        let first = off_t(offset) - off_t(count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, count - filled, first + off_t(filled))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            // Shorter than `offset`: the file shrank.
            if n == 0 { return nil }
            filled += n
        }
        return Data(buffer)
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
