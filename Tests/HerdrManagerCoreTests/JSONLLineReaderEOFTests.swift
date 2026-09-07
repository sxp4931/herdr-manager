import Foundation
import Testing
@testable import HerdrManagerCore

@Suite("JSONLLineReader EOF tail")
struct JSONLLineReaderEOFTests {
    @Test("JSONL reader emits the last line when the file has no trailing newline")
    func jsonlReaderEmitsUnterminatedLastLine() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerJSONL-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }

        // Agent transcripts are appended to live; the newest record routinely
        // has no terminating newline yet. Dropping it under-counted usage.
        try #"{"id":"a"}\#n{"id":"b"}"#.write(to: file, atomically: true, encoding: .utf8)

        var delivered: [String] = []
        JSONLLineReader.forEachLine(in: file) { _, data in
            delivered.append(String(data: data, encoding: .utf8) ?? "")
        }
        #expect(delivered == [#"{"id":"a"}"#, #"{"id":"b"}"#])
    }

    @Test("JSONL reader emits a single unterminated line and skips an unterminated oversize tail")
    func jsonlReaderHandlesSingleLineAndOversizedTail() throws {
        let single = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerJSONL-one-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: single) }
        try #"{"only":1}"#.write(to: single, atomically: true, encoding: .utf8)

        var delivered: [String] = []
        JSONLLineReader.forEachLine(in: single) { _, data in
            delivered.append(String(data: data, encoding: .utf8) ?? "")
        }
        #expect(delivered == [#"{"only":1}"#])

        let oversize = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdrManagerJSONL-tailbig-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: oversize) }
        let junk = String(repeating: "z", count: JSONLLineReader.maxLineBytes + 4096)
        try "{\"keep\":1}\n\(junk)".write(to: oversize, atomically: true, encoding: .utf8)

        var sizes: [Int] = []
        JSONLLineReader.forEachLine(in: oversize) { _, data in
            sizes.append(data.count)
        }
        #expect(sizes == [#"{"keep":1}"#.utf8.count])
    }
}
