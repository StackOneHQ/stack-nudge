import Foundation

// Reverse line reader for append-only JSONL transcripts.
//
// All three transcript readers (Claude, Codex, pi) want the *last* line
// matching a predicate: the newest assistant turn, the newest token_count.
// Reading the whole file to find it cost a full copy of the file —
// `Data(contentsOf:options:.mappedIfSafe)` maps lazily, but the
// `String(data:encoding:)` on the next line materialises every byte. Measured
// on a 241 MB Claude transcript that was 249 MB resident and 3.07s of CPU to
// recover a handful of trailing bytes, once per active session per refresh.
//
// This walks backwards in chunks instead, yielding complete lines newest
// first and stopping as soon as the caller has what it needs.
enum TranscriptTail {

    static let defaultChunkSize = 64 * 1024

    // Stop after this much of the tail. The newest usage-bearing line sits
    // within a few KB of the end in every transcript we have looked at; this
    // is the backstop for a pathological file, large enough to be reached only
    // by something genuinely strange and still two orders of magnitude below
    // the file sizes that caused the original problem.
    static let defaultMaxBytes = 8 * 1024 * 1024

    // Yield complete lines from the end of `path`, newest first, until `body`
    // returns true (meaning "stop") or the budget is spent.
    //
    // Lines are handed over as raw bytes, split on 0x0A. A UTF-8 continuation
    // byte is always 0x80–0xBF, so a newline byte can never fall inside a
    // multi-byte character and splitting on bytes cannot cut one in half.
    // Decoding a chunk to a String first would walk straight into that — the
    // same hazard PiTranscriptReader.sessionHeader documents for its prefix
    // read, where a straddling character silently loses an intact header.
    static func scanLinesBackwards(path: String,
                                   chunkSize: Int = defaultChunkSize,
                                   maxBytes: Int = defaultMaxBytes,
                                   _ body: (Data) -> Bool) {
        guard chunkSize > 0, maxBytes > 0,
              let handle = FileHandle(forReadingAtPath: path)
        else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return }

        var offset = Int(end)
        var consumed = 0

        // Bytes of the line straddling the start of what we have read so far.
        // Its beginning lies earlier in the file, so it cannot be emitted until
        // an earlier chunk completes it — or until we reach offset 0, where it
        // is the file's first line and therefore already whole.
        var carry = Data()

        while offset > 0 && consumed < maxBytes {
            let size = min(chunkSize, offset, maxBytes - consumed)
            offset -= size
            consumed += size
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let chunk = try? handle.read(upToCount: size),
                  chunk.count == size
            else { return }

            var buffer = chunk
            buffer.append(carry)

            guard let firstNewline = buffer.firstIndex(of: 0x0A) else {
                // No line boundary in this chunk: the whole buffer is still one
                // unfinished line. Keep walking back for its start.
                carry = buffer
                continue
            }

            // Everything past the first newline is whole lines; everything
            // before it belongs to a line that starts earlier still.
            let complete = buffer[buffer.index(after: firstNewline)...]
            carry = Data(buffer[..<firstNewline])
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                if body(Data(line)) { return }
            }
        }

        // Reached the start of the file: the carry is its first line, complete.
        // A budget-exhausted carry is NOT emitted — it is a fragment, and
        // handing a truncated line to a JSON parser would at best fail and at
        // worst parse into something wrong.
        if offset == 0 && !carry.isEmpty {
            _ = body(carry)
        }
    }
}
