import Foundation

struct Config {
    var title: String = "Claude Code"
    var message: String = "Done"
    var sound: String = "Glass"
    var activateBundleID: String? = nil
    var activateImmediately: Bool = false
    var windowTitle: String? = nil
    var ipcHook: String? = nil
    var projectPath: String? = nil
    var timeout: TimeInterval = 30.0
    var hasActionButton: Bool = false

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--title":
                i += 1; if i < args.count { title = args[i] }
            case "--message":
                i += 1; if i < args.count { message = args[i] }
            case "--sound":
                i += 1; if i < args.count { sound = args[i] }
            case "--activate":
                i += 1; if i < args.count { activateBundleID = args[i] }
            case "--activate-immediately":
                activateImmediately = true
            case "--window-title":
                i += 1; if i < args.count { windowTitle = args[i] }
            case "--ipc-hook":
                i += 1; if i < args.count { ipcHook = args[i] }
            case "--project-path":
                i += 1; if i < args.count { projectPath = args[i] }
            case "--has-action-button":
                hasActionButton = true
            case "--timeout":
                i += 1; if i < args.count { timeout = Double(args[i]) ?? timeout }
            default:
                break
            }
            i += 1
        }
    }
}
