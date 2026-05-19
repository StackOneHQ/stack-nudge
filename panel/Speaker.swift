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
