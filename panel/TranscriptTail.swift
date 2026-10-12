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

    // Open `path` for reading, and only if it is a regular file, without ever
    // blocking on the open itself.
    //
    // `FileHandle(forReadingAtPath:)` blocks in open(2) indefinitely on a FIFO
    // with no writer. That is reachable: PiTranscriptReader.locate picks
    // transcript paths out of a sessions directory by mtime, so a FIFO sitting
    // there would be handed straight to a reader. It matters more than it looks
    // because every transcript read now shares one serial queue — a single such
    // open would wedge stats for every session, not just the one holding the
    // FIFO, and nothing would time it out.
    //
    // O_NONBLOCK makes the open return immediately on a FIFO; it has no effect
    // on a regular file, which is the only kind we go on to accept. The caller
    // gets the stat as well, since it is needed anyway and this is the one open
    // that proves the file both exists and is readable.
    static func openRegularFile(_ path: String) -> (handle: FileHandle, info: stat)? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return nil
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: false), info)
    }

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
    // Returns whether the scan reached a natural end — the start of the file,
    // the budget, or the caller saying stop. `false` means it could not open or
    // could not read the file, which is NOT the same as finding nothing: the
    // memoisation in TranscriptReader.cached refuses to cache a nil that came
    // from a false, because nothing about such a file has to change before it
    // would succeed, so the nil would stick forever. An empty file is a clean
    // `true` — there is genuinely nothing in it.
    @discardableResult
    static func scanLinesBackwards(path: String,
                                   chunkSize: Int = defaultChunkSize,
                                   maxBytes: Int = defaultMaxBytes,
                                   _ body: (Data) -> Bool) -> Bool {
        guard chunkSize > 0, maxBytes > 0 else { return false }
        guard let opened = openRegularFile(path) else { return false }
        let handle = opened.handle
        defer { try? handle.close() }
        if opened.info.st_size == 0 { return true }

        var offset = Int(opened.info.st_size)
        var consumed = 0

        // Pieces of the line straddling the start of what we have read, each
        // piece earlier in the file than the one appended before it — so the
        // line in file order is `carryParts` reversed and joined.
        //
        // Held as pieces rather than one growing blob on purpose. Appending the
        // accumulated carry into a fresh buffer once per chunk makes a long
        // line quadratic in its length: at the default chunk size a 1.3 MB line
        // — the longest in any transcript on this machine — copies ~13 MB, and
        // the cost grows with the square, so a line at the budget ceiling would
        // burn over a second to yield nothing. Appending a piece is O(1)
        // amortised and each byte is copied once.
        //
        // No piece ever contains a newline, which is what lets the search below
        // look at the incoming chunk alone rather than at the join.
        var carryParts: [Data] = []

        func assembledCarry() -> Data {
            var out = Data()
            for part in carryParts.reversed() { out.append(part) }
            return out
        }

        while offset > 0 && consumed < maxBytes {
            let size = min(chunkSize, offset, maxBytes - consumed)
            offset -= size
            consumed += size
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let chunk = try? handle.read(upToCount: size),
                  chunk.count == size
            else { return false }

            guard let firstNewline = chunk.firstIndex(of: 0x0A),
                  let lastNewline = chunk.lastIndex(of: 0x0A)
            else {
                // No line boundary here: the whole chunk belongs to the line
                // still being assembled. Keep walking back for its start.
                carryParts.append(chunk)
                continue
            }

            // The bytes after this chunk's LAST newline, followed by everything
            // carried, form one whole line — that newline proves where it
            // starts. This is the only place the carry is concatenated, so each
            // carried byte is copied exactly once.
            var tail = Data(chunk[chunk.index(after: lastNewline)...])
            for part in carryParts.reversed() { tail.append(part) }
            carryParts.removeAll(keepingCapacity: true)
            if !tail.isEmpty, body(tail) { return true }

            // Lines lying wholly inside this chunk, between its first and last
            // newline, newest first. When the chunk holds a single newline
            // there is no such region — and the range would be invalid.
            if firstNewline != lastNewline {
                let middle = chunk[chunk.index(after: firstNewline)..<lastNewline]
                for line in middle.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                    if body(Data(line)) { return true }
                }
            }

            // Before the first newline: a line that starts earlier still.
            carryParts.append(Data(chunk[..<firstNewline]))
        }

        // Reached the start of the file: the carry is its first line, complete.
        // A budget-exhausted carry is NOT emitted — it is a fragment, and
        // handing a truncated line to a JSON parser would at best fail and at
        // worst parse into something wrong.
        if offset == 0 {
            let carry = assembledCarry()
            if !carry.isEmpty { _ = body(carry) }
        }
        return true
    }
}
