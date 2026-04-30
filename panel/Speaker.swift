import Foundation

// Thin wrapper around stackvox-say. Spawns the daemon if its socket isn't
// up yet (mirrors notify.sh's auto-start) and falls back to a no-op if
// stackvox isn't installed in the venv.
enum Speaker {

    static func speak(_ text: String, voice: String? = nil, speed: String? = nil) {
        let venvBin = "\(NSHomeDirectory())/.stack-nudge/venv/bin"
        let stackvoxSay = "\(venvBin)/stackvox-say"
        let stackvox    = "\(venvBin)/stackvox"
        let socketPath  = "\(NSHomeDirectory())/.cache/stackvox/daemon.sock"
        guard FileManager.default.isExecutableFile(atPath: stackvoxSay) else { return }

        if !FileManager.default.fileExists(atPath: socketPath),
           FileManager.default.isExecutableFile(atPath: stackvox) {
            let serve = Process()
            serve.executableURL = URL(fileURLWithPath: stackvox)
            serve.arguments = ["serve"]
            try? serve.run()
        }

        let config = ConfigFile.read()
        let resolvedVoice = voice ?? config["STACKNUDGE_VOICE_NAME"]  ?? "af_heart"
        let resolvedSpeed = speed ?? config["STACKNUDGE_VOICE_SPEED"] ?? "1.1"
        let say = Process()
        say.executableURL = URL(fileURLWithPath: stackvoxSay)
        say.arguments = ["--voice", resolvedVoice, "--speed", resolvedSpeed, text]
        try? say.run()
    }
}
