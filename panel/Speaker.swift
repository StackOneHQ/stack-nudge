import Foundation

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
        try? say.run()
    }
}
