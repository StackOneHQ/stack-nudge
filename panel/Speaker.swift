import Foundation
import AppKit

// Thin wrapper around the stackvox CLI. Spawns the daemon if its socket
// isn't up yet (mirrors notify.sh's auto-start) and falls back to a no-op
// if stackvox isn't installed in the venv.
//
// stackvox 0.3.x consolidated its CLI — there's no separate `stackvox-say`
// binary anymore; speech goes through `stackvox say <text>` as a subcommand.
enum Speaker {

    static func speak(_ text: String, voice: String? = nil, speed: String? = nil) {
        let venvBin = "\(NSHomeDirectory())/.stack-nudge/venv/bin"
        let stackvox    = "\(venvBin)/stackvox"
        let socketPath  = "\(NSHomeDirectory())/.cache/stackvox/daemon.sock"
        guard FileManager.default.isExecutableFile(atPath: stackvox) else { return }

        if !FileManager.default.fileExists(atPath: socketPath) {
            let serve = Process()
            serve.executableURL = URL(fileURLWithPath: stackvox)
            serve.arguments = ["serve"]
            // Same espeak-ng data-path workaround as the launchd plist —
            // the wheel's libespeak-ng.dylib has a CI-build phontab path
            // baked in; ESPEAK_DATA_PATH overrides it at runtime.
            let venvURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.stack-nudge/venv")
                .resolvingSymlinksInPath()
            var env = ProcessInfo.processInfo.environment
            env.merge(Bootstrap.stackvoxEnv(venvURL: venvURL)) { _, new in new }
            serve.environment = env
            try? serve.run()
        }

        let config = ConfigFile.read()
        let resolvedVoice = voice ?? config["STACKNUDGE_VOICE_NAME"]  ?? "af_aoede"
        let resolvedSpeed = speed ?? config["STACKNUDGE_VOICE_SPEED"] ?? "1.1"
        let say = Process()
        say.executableURL = URL(fileURLWithPath: stackvox)
        say.arguments = ["say", "--voice", resolvedVoice, "--speed", resolvedSpeed, text]
        say.standardOutput = FileHandle.nullDevice
        say.standardError = FileHandle.nullDevice
        say.terminationHandler = { ended in
            audioLock.lock(); defer { audioLock.unlock() }
            activeAudio.removeAll { $0 === ended }
        }
        do {
            try say.run()
            audioLock.lock()
            activeAudio.append(say)
            audioLock.unlock()
        } catch {
            // best-effort; stackvox missing → silent fallback
        }
    }

    // Play a /System/Library/Sounds/*.aiff chime. The afplay path is identical
    // to what notify.sh used; we keep it as a Process call (rather than NSSound)
    // because afplay terminates on app quit — fixing the "bell keeps ringing
    // after quitting stack-nudge" complaint that motivated this move. NSSound
    // would play asynchronously without that lifecycle guarantee.
    @discardableResult
    static func playSound(named name: String) -> Process? {
        let path = "/System/Library/Sounds/\(name).aiff"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // Track so applicationWillTerminate can kill any still-playing
        // afplay children — the whole point of moving this in-app is that
        // quitting the app stops the bell.
        p.terminationHandler = { ended in
            audioLock.lock(); defer { audioLock.unlock() }
            activeAudio.removeAll { $0 === ended }
        }
        do {
            try p.run()
            audioLock.lock()
            activeAudio.append(p)
            audioLock.unlock()
            return p
        } catch {
            return nil
        }
    }

    // stackvox uses kokoro-onnx (not HF kokoro). The ~340 MB model + voice
    // pack live in ~/.cache/stackvox/, downloaded lazily from GitHub
    // Releases the first time anything instantiates StackvoxEngine.
    // Override via STACKVOX_CACHE_DIR (we don't, but stackvox honours it).
    static let voiceModelDir = "\(NSHomeDirectory())/.cache/stackvox"
    static let voiceModelFile = "\(voiceModelDir)/kokoro-v1.0.onnx"
    static let voicePackFile  = "\(voiceModelDir)/voices-v1.0.bin"

    // Expected file sizes for the GitHub release we pin against. Used to
    // detect interrupted downloads — stackvox's `_ensure_models` only
    // checks file existence, so a half-written file from a previous
    // crashed/cancelled run will be left in place and load attempts will
    // fail with InvalidProtobuf. We flag those as "not cached" so the
    // UI re-offers the download.
    //
    // Minimums (not exact match) give us tolerance for HEAD updates that
    // bump the file slightly while still catching obvious truncations.
    private static let voiceModelMinBytes: Int = 320_000_000   // real: ~325 MB
    private static let voicePackMinBytes:  Int = 27_000_000    // real: ~28 MB

    static func voiceModelCached() -> Bool {
        let fm = FileManager.default
        let pairs: [(String, Int)] = [
            (voiceModelFile, voiceModelMinBytes),
            (voicePackFile,  voicePackMinBytes),
        ]
        for (path, minSize) in pairs {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber,
                  size.intValue >= minSize
            else { return false }
        }
        return true
    }

    // Force-fetch the kokoro model + voice pack by instantiating
    // stackvox's engine in a one-shot Python subprocess. The engine's
    // `_ensure_models()` writes the files into ~/.cache/stackvox/ and
    // emits its own progress lines on stderr:
    //   `[stackvox] downloading model  45% (152 MB)`
    // No synthesis runs (we never call .speak()), so no audio plays —
    // exactly what we want for a pre-warm.
    //
    // Returns the Process so the caller can terminate() it to cancel.
    @discardableResult
    static func downloadVoiceModel(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Error?) -> Void
    ) -> Process? {
        let venvBin = "\(NSHomeDirectory())/.stack-nudge/venv/bin"
        let python = "\(venvBin)/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            completion(NSError(domain: "Speaker", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "python3 not found in venv"]))
            return nil
        }

        // Defensive cleanup: stackvox's `_ensure_models` only checks
        // file existence, so a previously-interrupted download leaves a
        // partial file that the engine then fails to load (InvalidProtobuf).
        // Always start from a clean slate when the user clicks Download.
        let fm = FileManager.default
        for path in [voiceModelFile, voicePackFile] {
            try? fm.removeItem(atPath: path)
        }

        // Minimal script: call the private helper that downloads both
        // files into the default cache dir, no engine init, no synthesis.
        let script = """
        from stackvox.engine import _ensure_models
        from stackvox.paths import cache_dir
        _ensure_models(cache_dir())
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-u", "-c", script]   // -u: unbuffered stdout/stderr

        let venvURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.stack-nudge/venv")
            .resolvingSymlinksInPath()
        var env = ProcessInfo.processInfo.environment
        env.merge(Bootstrap.stackvoxEnv(venvURL: venvURL)) { _, new in new }
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice

        // stackvox progress format (engine.py:_download_with_progress):
        //   `\r[stackvox] downloading model  45% (152 MB)`
        // One label per file (model + voices); we just take whichever
        // percent we last saw — UX is "bar moves forward then resets
        // for the second file".
        let regex = try? NSRegularExpression(pattern: #"\[stackvox\] downloading \S+\s+(\d{1,3})%"#)
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.components(separatedBy: CharacterSet(charactersIn: "\r\n")).reversed() {
                guard let regex,
                      let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(m.range(at: 1), in: line),
                      let pct = Int(line[range])
                else { continue }
                let value = max(0.0, min(1.0, Double(pct) / 100.0))
                DispatchQueue.main.async { progress(value) }
                break
            }
        }

        p.terminationHandler = { ended in
            errPipe.fileHandleForReading.readabilityHandler = nil
            audioLock.lock(); defer { audioLock.unlock() }
            activeAudio.removeAll { $0 === ended }

            DispatchQueue.main.async {
                if ended.terminationStatus == 0 {
                    // Post-download integrity check: stackvox can exit 0
                    // with a truncated file if the source server closed
                    // the stream early. Verify the file is at least its
                    // expected minimum size before claiming success.
                    if voiceModelCached() {
                        completion(nil)
                    } else {
                        let onnxSize = (try? FileManager.default
                            .attributesOfItem(atPath: voiceModelFile))?[.size] as? Int ?? 0
                        completion(NSError(domain: "Speaker", code: 3,
                            userInfo: [NSLocalizedDescriptionKey:
                                "Download truncated — got \(onnxSize / 1_000_000) MB, expected ~325 MB. Try again."]))
                    }
                } else {
                    // SIGTERM (15) = user cancelled, not a real error.
                    if ended.terminationReason == .uncaughtSignal {
                        completion(NSError(domain: "Speaker", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
                    } else {
                        completion(NSError(domain: "Speaker", code: Int(ended.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey:
                                "stackvox exited \(ended.terminationStatus)"]))
                    }
                }
            }
        }

        do {
            try p.run()
            audioLock.lock()
            activeAudio.append(p)
            audioLock.unlock()
            return p
        } catch {
            completion(error)
            return nil
        }
    }

    // Kill any in-flight afplay or stackvox children. Called from
    // PanelController.applicationWillTerminate so a user-initiated Quit
    // also silences the audio that this event chain spawned.
    static func stopAllAudio() {
        audioLock.lock()
        let snapshot = activeAudio
        activeAudio.removeAll()
        audioLock.unlock()
        for p in snapshot where p.isRunning {
            p.terminate()
        }
    }
}

private var activeAudio: [Process] = []
private let audioLock = NSLock()
