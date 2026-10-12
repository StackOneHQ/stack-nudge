import XCTest

@testable import StackNudgePanelCore

// TranscriptReader.read memoises on (size, mtime) because the refresh poll
// re-reads every active session's transcript on a cadence while a transcript
// only changes when its agent writes a turn. Two properties matter and are
// easy to break in opposite directions: an unchanged file must not be re-read,
// and a changed one must not serve a stale answer.
final class TranscriptReaderCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TranscriptReader.resetCache()
    }

    override func tearDown() {
        TranscriptReader.resetCache()
        super.tearDown()
    }

    private func assistant(tokens: Int, model: String = "claude-opus-5") -> String {
        """
        {"type":"assistant","message":{"model":"\(model)","usage":{"input_tokens":\(tokens),\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    private func write(_ lines: [String]) -> String {
        let dir = NSTemporaryDirectory() + "transcript-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "session.jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func rewrite(_ path: String, _ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // A whole-second instant, stamped on the file both before the first read
    // and after the rewrite. Capturing the file's own mtime and restoring it
    // does not work: a filesystem timestamp has nanosecond resolution, a Date
    // cannot represent that many significant digits, and setAttributes writes
    // back what the Date holds — measured, …729.521561435 restores as
    // …729.521561000. The "restored" mtime therefore differs from the
    // original and the fingerprint misses. Stamping the same exact
    // microsecond-clean value twice is what makes the two reads agree.
    private let frozenMtime = Date(timeIntervalSince1970: 1_700_000_000)

    private func freezeMtime(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: frozenMtime],
                                               ofItemAtPath: path)
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                       frozenMtime, "mtime did not round-trip; the test cannot hold the fingerprint still")
    }

    // Replace the file's contents while holding (size, mtime) exactly where
    // they were — padding to the original byte length, then re-freezing the
    // mtime. The fingerprint is then identical and the content is not, so the
    // only thing that can tell the two apart is the memoisation. Deleting the
    // file would not do: an unstattable path deliberately falls through to the
    // parse rather than serve a hit, so a nil there proves nothing.
    private func rewritePreservingFingerprint(_ path: String, _ line: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0

        // Trailing whitespace before the newline is legal JSON and is carried
        // through to the parser verbatim, so it pads without changing meaning.
        var body = line
        XCTAssertLessThanOrEqual(body.utf8.count + 1, size, "cannot pad up to \(size) bytes")
        while body.utf8.count + 1 < size { body += " " }

        // Written through an open handle, NOT with write(toFile:atomically:),
        // which renames a fresh file over the path and so changes the inode —
        // which the fingerprint now (correctly) notices. Holding the
        // fingerprint still means overwriting the same file in place.
        guard let handle = FileHandle(forUpdatingAtPath: path) else {
            return XCTFail("could not open \(path) for updating")
        }
        try? handle.seek(toOffset: 0)
        handle.write(Data((body + "\n").utf8))
        try? handle.truncate(atOffset: UInt64(size))
        try? handle.close()
        freezeMtime(path)

        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size)
    }

    // The tail scan must look past trailing non-assistant lines — a transcript
    // almost always ends on a user or tool entry, so a reader that only
    // inspected the final line would report nothing.
    func testSkipsTrailingNonAssistantLines() {
        let path = write([assistant(tokens: 77),
                          #"{"type":"user","message":{"role":"user"}}"#,
                          #"{"type":"system","subtype":"hook"}"#])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 77)
    }

    // An unchanged file serves the memoised answer rather than re-reading.
    // Proven by swapping the content underneath a frozen fingerprint: a reader
    // that went to disk would return the new number, so the old number can
    // only have come from the cache.
    func testUnchangedFileIsNotReRead() {
        let path = write([assistant(tokens: 410)])
        freezeMtime(path)
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 410)

        rewritePreservingFingerprint(path, assistant(tokens: 999))
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 410,
                       "same size and mtime must serve the cached answer, not re-read")
    }

    // The other direction, and the one that would ship wrong numbers silently:
    // a transcript that grew must be re-read. Size alone catches this even when
    // mtime granularity would not.
    func testChangedFileIsReRead() {
        let path = write([assistant(tokens: 100)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 100)

        rewrite(path, [assistant(tokens: 100), assistant(tokens: 900)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 900)
    }

    // A same-size rewrite is the case size cannot catch, so mtime has to. The
    // sleep is the point rather than incidental: it puts the two writes in
    // different mtime ticks, which is what the fingerprint relies on.
    func testSameSizeRewriteIsReReadOnMtime() {
        let path = write([assistant(tokens: 111)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 111)

        Thread.sleep(forTimeInterval: 1.1)
        rewrite(path, [assistant(tokens: 222)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 222)
    }

    // And the mirror case, which is what makes `size` part of the fingerprint
    // rather than decoration: a transcript that grew while its mtime stayed
    // put must still be re-read. mtime alone passes every other test here
    // (APFS timestamps are nanosecond-resolution, so an append practically
    // always moves them), so without this the size field could be deleted and
    // nothing would notice until a file arrived with a stale timestamp — from
    // a restore, a copy, or a clock that stepped backwards.
    func testGrowthWithAnUnchangedMtimeIsReReadOnSize() {
        let path = write([assistant(tokens: 300)])
        freezeMtime(path)
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 300)

        rewrite(path, [assistant(tokens: 300), assistant(tokens: 800)])
        freezeMtime(path)
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 800,
                       "a changed size must re-read even when the mtime is identical")
    }

    // A nil is memoised too — a transcript with no assistant turn yet is the
    // one most likely to be polled repeatedly to no effect. Same proof: a real
    // re-read under a frozen fingerprint would find the assistant line.
    func testNilResultIsMemoised() {
        let path = write([#"{"type":"user","note":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#])
        freezeMtime(path)
        XCTAssertNil(TranscriptReader.read(path: path))

        rewritePreservingFingerprint(path, assistant(tokens: 500))
        XCTAssertNil(TranscriptReader.read(path: path),
                     "an unchanged fingerprint must keep serving the memoised nil")
    }

    // A symlinked transcript path must be fingerprinted by its TARGET, not by
    // the link. `FileManager.attributesOfItem` does not follow symlinks while
    // the reader does, so fingerprinting through it froze the link's own size
    // (the length of its target path) and mtime (when the link was made) —
    // neither of which moves while an agent appends. The session's token count
    // would stick at its first reading for the life of the process.
    func testASymlinkedPathFollowsItsTarget() {
        let dir = NSTemporaryDirectory() + "transcript-link-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let target = dir + "target.jsonl"
        let link = dir + "link.jsonl"
        try? (assistant(tokens: 1000) + "\n").write(toFile: target, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        XCTAssertEqual(TranscriptReader.read(path: link)?.tokens, 1000)

        // Append through the target. The link's own stat does not budge.
        try? ([assistant(tokens: 1000), assistant(tokens: 250_000)].joined(separator: "\n") + "\n")
            .write(toFile: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptReader.read(path: link)?.tokens, 250_000,
                       "the fingerprint must track the target, not the link")
    }

    // A file that stats but cannot be opened must not have its nil memoised. A
    // chmod touches ctime only — size and mtime are byte-identical either side
    // of it — so a nil cached against that fingerprint could never heal, and
    // the session would read as having no stats until the app restarted.
    // Reachable without any permissions game via EMFILE under the read
    // fan-out, a transcript owned by another uid, or a dangling symlink.
    func testAnUnreadableFileDoesNotMemoiseItsNil() {
        let path = write([assistant(tokens: 4242)])
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        // root can read a mode-000 file, so the premise would not hold there.
        guard FileHandle(forReadingAtPath: path) == nil else { return }
        XCTAssertNil(TranscriptReader.read(path: path))

        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 4242,
                       "a nil from a file that could not be opened must not be cached")
    }

    // The same asymmetry through a dangling symlink, which stats fine (the link
    // exists) but cannot be opened. Once the target appears the stats must
    // resolve rather than stay pinned to the cached nil.
    func testADanglingSymlinkDoesNotMemoiseItsNil() {
        let dir = NSTemporaryDirectory() + "transcript-dangling-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let target = dir + "target.jsonl"
        let link = dir + "link.jsonl"
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        XCTAssertNil(TranscriptReader.read(path: link))

        try? (assistant(tokens: 606) + "\n").write(toFile: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptReader.read(path: link)?.tokens, 606,
                       "a nil from a dangling link must not outlive the link going live")
    }

    // (size, mtime) alone is reproducible by an atomic replace: a different
    // file renamed over the path with the same byte length and the times
    // copied across, which is what `cp -p`, `rsync -t`, `touch -r` and a
    // restore from backup all do. Size and mtime then match while the contents
    // do not, and the stale answer would be served for the life of the
    // process. The device and inode make the swap visible.
    //
    // Built with `touch -r` rather than by hand so the mtime is copied at the
    // filesystem's own resolution — a Date cannot carry those digits, so
    // setAttributes could not express this case at all.
    func testAnAtomicReplaceWithCopiedTimesIsNoticed() {
        let path = write([assistant(tokens: 1111)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 1111)

        // Same byte length, different contents, in a separate file.
        let replacement = (path as NSString).deletingLastPathComponent + "/replacement.jsonl"
        var body = assistant(tokens: 9999)
        let want = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        while body.utf8.count + 1 < want { body += " " }
        try? (body + "\n").write(toFile: replacement, atomically: true, encoding: .utf8)

        // Copy the original's timestamps onto it, then rename it over.
        let touch = Process()
        touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        touch.arguments = ["-r", path, replacement]
        try? touch.run()
        touch.waitUntilExit()
        try? FileManager.default.replaceItem(at: URL(fileURLWithPath: path),
                                             withItemAt: URL(fileURLWithPath: replacement),
                                             backupItemName: nil,
                                             resultingItemURL: nil)

        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 9999,
                       "an atomic replace that preserves size and mtime must still be noticed")
    }

    // Two mtimes one nanosecond apart must be distinguishable. They are not if
    // the fingerprint holds seconds as a Double: at this epoch a Double's
    // resolution is 120 ns (measured), so a nanosecond-scale change vanishes
    // and a rewrite inside that window would serve the stale answer.
    //
    // Set with utimensat, which is the only way to write an exact nanosecond
    // mtime — setAttributes truncates to the microsecond, so it cannot build
    // this case at all. Size and inode are held constant by writing in place,
    // leaving the nanoseconds as the only difference.
    func testOneNanosecondOfMtimeIsEnoughToReRead() {
        let path = write([assistant(tokens: 700)])

        func setMtime(nanoseconds: Int) {
            var times = [timespec(tv_sec: 1_791_813_089, tv_nsec: 0),
                         timespec(tv_sec: 1_791_813_089, tv_nsec: nanoseconds)]
            XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0, "could not set the mtime")
        }

        setMtime(nanoseconds: 123_456_789)
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 700)

        // Same bytes count, same inode, mtime one nanosecond later.
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        var body = assistant(tokens: 900)
        while body.utf8.count + 1 < size { body += " " }
        if let handle = FileHandle(forUpdatingAtPath: path) {
            try? handle.seek(toOffset: 0)
            handle.write(Data((body + "\n").utf8))
            try? handle.truncate(atOffset: UInt64(size))
            try? handle.close()
        }
        setMtime(nanoseconds: 123_456_790)

        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 900,
                       "a one-nanosecond mtime change must invalidate the entry")
    }

    // The cacheability rule, directly. Stats present is always worth keeping.
    // A nil is worth keeping only when the read actually happened — otherwise
    // the failure would be memoised against a fingerprint that need never
    // change again, and the session would show no stats until a restart.
    func testOnlyAnEvidencedNilIsCacheable() {
        let stats = TranscriptStats(tokens: 1, model: nil)
        XCTAssertTrue(TranscriptReader.isCacheable(stats: stats, complete: true))
        XCTAssertFalse(TranscriptReader.isCacheable(stats: stats, complete: false),
                       "the Codex reader can find tokens and then fail before the model, "
                       + "so a partial result would freeze a nil model in place")
        XCTAssertTrue(TranscriptReader.isCacheable(stats: nil, complete: true),
                      "a complete read that found nothing is evidence of nothing being there")
        XCTAssertFalse(TranscriptReader.isCacheable(stats: nil, complete: false),
                       "a nil from a read that never got off the ground must not stick")
    }

    // An unstattable path must not serve another path's answer, and must not
    // crash. It falls through to the parse, which fails the same way.
    func testMissingFileReturnsNil() {
        XCTAssertNil(TranscriptReader.read(path: "/nonexistent/\(UUID().uuidString).jsonl"))
    }
}
