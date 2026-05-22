import Foundation

// Tiny helper for shelling out and reading stdout. Used by SessionStore
// (ps/lsof) and the terminal integrations (ps -eww). Centralised so
// every caller gets the same "swallow stderr, return empty string on
// any failure" contract — we never want a flaky subprocess to surface
// as a panel crash.
enum ProcessOutput {
    static func read(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
