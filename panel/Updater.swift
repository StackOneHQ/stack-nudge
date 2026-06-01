import AppKit
import CryptoKit
import Foundation
import SwiftUI

// Phase of the auto-update flow. Drives the progress UI in UpdatingView.
// Updated in-place from Swift as each step of the download/swap pipeline
// completes — no longer driven by a shell runner's STAGE markers.
enum UpdatePhase: String {
    case idle
    case fetching       // GET /releases/latest
    case downloading    // streaming the .tar.gz
    case verifying      // SHA256 check
    case extracting     // tar -xzf
    case installing     // atomic swap + launchctl kickstart
    case done
    case failed
}

extension UpdatePhase {
    var label: String {
        switch self {
        case .idle:        return "Preparing…"
        case .fetching:    return "Fetching release…"
        case .downloading: return "Downloading update…"
        case .verifying:   return "Verifying checksum…"
        case .extracting:  return "Extracting…"
        case .installing:  return "Installing…"
        case .done:        return "Restarting stack-nudge…"
        case .failed:      return "Update failed"
        }
    }

    var step: Int {
        switch self {
        case .idle:        return 0
        case .fetching:    return 1
        case .downloading: return 2
        case .verifying:   return 3
        case .extracting:  return 4
        case .installing:  return 5
        case .done, .failed: return 6
        }
    }

    static let totalSteps: Int = 6
}

// Click-to-update flow: download the latest signed/notarized artifact from
// GitHub Releases, verify its sha256, atomic-swap the existing bundle, kick
// launchd → new bundle starts. No shell runner, no source clone, no rebuild
// — the artifact is already what we want.
//
// On success we write /tmp/stack-nudge-update-status.json before triggering
// the relaunch, so the new bundle picks up the "Updated to vX.Y.Z" welcome
// view on its first launch.
final class Updater {

    static let statusPath = "/tmp/stack-nudge-update-status.json"
    static let releasesAPI = URL(
        string: "https://api.github.com/repos/StackOneHQ/stack-nudge/releases/latest"
    )!
    static let releasesGHPath = "repos/StackOneHQ/stack-nudge/releases/latest"

    private weak var nav: PanelNav?
    private let session: URLSession

    init(nav: PanelNav) {
        self.nav = nav
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 1800  // bundle is ~200 MB; allow up to 30 min
        self.session = URLSession(configuration: cfg)
    }

    // Kicks off the update on a background queue. Returns immediately;
    // progress flows back via nav.updaterPhase / nav.updaterLog.
    func run() {
        guard let nav else { return }
        DispatchQueue.main.async {
            nav.updaterPhase = .idle
            nav.updaterLog = ""
            nav.mode = .updating
        }

        // Wipe any prior status file so the new bundle doesn't see stale
        // success/failure from a previous run.
        try? FileManager.default.removeItem(atPath: Self.statusPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.performUpdate()
            } catch {
                self.fail(error)
            }
        }
    }

    // MARK: - Pipeline

    private func performUpdate() throws {
        // 1. Resolve which artifact to download.
        setPhase(.fetching)
        appendLog("Fetching release manifest…")
        let release = try fetchRelease()
        appendLog("Latest release: v\(release.version)")

        let arch = currentArch()
        guard let asset = release.assets.first(where: {
            $0.name.contains("-macos-\(arch).tar.gz") && !$0.name.hasSuffix(".sha256")
        }) else {
            throw UpdateError.noArtifactForArch(arch: arch)
        }
        let shaAsset = release.assets.first {
            $0.name == "\(asset.name).sha256"
        }
        appendLog("Selected artifact: \(asset.name) (\(byteCount(asset.size)))")

        // 2. Download the .tar.gz.
        setPhase(.downloading)
        let tarballURL = try downloadAsset(url: asset.downloadURL,
                                          expectedSize: asset.size)
        appendLog("Downloaded to \(tarballURL.path)")

        // 3. Verify checksum if a sidecar was published.
        if let sha = shaAsset {
            setPhase(.verifying)
            try verifyChecksum(tarballURL: tarballURL,
                               shaAssetURL: sha.downloadURL,
                               assetName: asset.name)
            appendLog("Checksum OK")
        } else {
            appendLog("No .sha256 sidecar — skipping checksum (release isn't yet wired for it)")
        }

        // 4. Extract.
        setPhase(.extracting)
        let extractedAppURL = try extractTarball(tarballURL)
        appendLog("Extracted to \(extractedAppURL.path)")

        // 5. Strip quarantine xattr so the new bundle doesn't trigger
        //    Gatekeeper "downloaded from the internet" prompts.
        try stripQuarantine(at: extractedAppURL)

        // 6. Atomic swap into ~/Applications/.
        setPhase(.installing)
        try atomicSwap(extractedAppURL: extractedAppURL)
        appendLog("Installed to \(Self.installedAppPath)")

        // 7. Write status file so the next launch surfaces the welcome view.
        try writeStatusFile(state: "success", version: release.version, error: nil)

        // 8. Restart launchd → current process dies, new bundle starts.
        setPhase(.done)
        appendLog("Restarting via launchd…")
        try kickstartLaunchd()

        // launchctl kickstart -k will SIGTERM us; if for some reason it
        // doesn't, fall back to a self-quit after a brief delay so the
        // user isn't stuck staring at "Restarting…" forever.
        scheduleAutoQuit()
    }

    // MARK: - Release manifest

    private struct ReleaseInfo {
        let version: String
        let assets: [Asset]
    }
    private struct Asset {
        let name: String
        let size: Int
        let downloadURL: URL
    }

    private func fetchRelease() throws -> ReleaseInfo {
        if let json = httpFetchJSON(Self.releasesAPI) {
            return try parseRelease(json)
        }
        // Fall back to gh CLI for private-repo dev cycles (same pattern as
        // UpdateChecker's poller).
        if let json = ghFetchJSON(Self.releasesGHPath) {
            return try parseRelease(json)
        }
        throw UpdateError.releaseFetchFailed
    }

    private func parseRelease(_ json: [String: Any]) throws -> ReleaseInfo {
        guard let tag = json["tag_name"] as? String else {
            throw UpdateError.malformedReleaseJSON("tag_name missing")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assetsRaw = (json["assets"] as? [[String: Any]]) ?? []
        let assets: [Asset] = assetsRaw.compactMap {
            guard let name = $0["name"] as? String,
                  let size = $0["size"] as? Int,
                  let urlStr = $0["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else { return nil }
            return Asset(name: name, size: size, downloadURL: url)
        }
        guard !assets.isEmpty else {
            throw UpdateError.malformedReleaseJSON("no assets attached to release")
        }
        return ReleaseInfo(version: version, assets: assets)
    }

    // Unauthenticated GitHub API call (public repo path). Returns nil on
    // 404 / 5xx so the caller can fall back to gh.
    private func httpFetchJSON(_ url: URL) -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("stack-nudge",                  forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            let http = response as? HTTPURLResponse
            guard let data, http?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            result = json
        }.resume()
        semaphore.wait()
        return result
    }

    // gh CLI fallback for private repos. Mirrors UpdateChecker.fetchViaGH.
    private func ghFetchJSON(_ apiPath: String) -> [String: Any]? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let ghPath = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ghPath)
        task.arguments = ["api", apiPath]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - Download

    // Downloads the asset via a regular dataTask + writes to disk. We use
    // dataTask (not downloadTask) because URLSession's authenticated-redirect
    // handling for GitHub's release CDN is fiddly, and the bundle size at
    // 200-ish MB is comfortably in-memory on modern Macs.
    private func downloadAsset(url: URL, expectedSize: Int) throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("stack-nudge",              forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var taskError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { taskError = error; return }
            let http = response as? HTTPURLResponse
            guard let data, http?.statusCode == 200 else {
                taskError = UpdateError.downloadHTTP(status: http?.statusCode ?? 0)
                return
            }
            resultData = data
        }
        task.resume()
        semaphore.wait()

        if let taskError { throw taskError }
        guard let data = resultData else {
            throw UpdateError.downloadHTTP(status: 0)
        }
        if expectedSize > 0, data.count != expectedSize {
            throw UpdateError.downloadSizeMismatch(expected: expectedSize, got: data.count)
        }

        // Write to a stable temp path so the rest of the pipeline can run
        // tar/xattr against it.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stack-nudge-update-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("stack-nudge.tar.gz")
        try data.write(to: dest)
        return dest
    }

    // MARK: - Verify

    private func verifyChecksum(tarballURL: URL,
                                shaAssetURL: URL,
                                assetName: String) throws {
        // The .sha256 sidecar is small (~64 bytes); reuse the JSON fetch
        // session for it via a plain dataTask. Body format: "<hex>  <name>".
        var request = URLRequest(url: shaAssetURL)
        request.setValue("text/plain",  forHTTPHeaderField: "Accept")
        request.setValue("stack-nudge", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var expectedHex: String?
        var fetchError: Error?
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { fetchError = error; return }
            let http = response as? HTTPURLResponse
            guard let data, http?.statusCode == 200,
                  let body = String(data: data, encoding: .utf8) else {
                fetchError = UpdateError.checksumFetchFailed
                return
            }
            // Take the first whitespace-separated token.
            expectedHex = body
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map(String.init)
        }.resume()
        semaphore.wait()
        if let err = fetchError { throw err }
        guard let expectedHex else { throw UpdateError.checksumFetchFailed }

        let data = try Data(contentsOf: tarballURL)
        let digest = SHA256.hash(data: data)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        if actualHex.lowercased() != expectedHex.lowercased() {
            throw UpdateError.checksumMismatch(expected: expectedHex, actual: actualHex,
                                               assetName: assetName)
        }
    }

    // MARK: - Extract + filesystem

    private func extractTarball(_ tarballURL: URL) throws -> URL {
        let workDir = tarballURL.deletingLastPathComponent()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xzf", tarballURL.path, "-C", workDir.path]
        task.standardOutput = Pipe()
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw UpdateError.extractFailed(stderr: err)
        }
        // Find the extracted .app — tarball wraps StackNudge.app at the top level.
        let contents = try FileManager.default
            .contentsOfDirectory(at: workDir,
                                 includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.extractFailed(stderr: "no .app in tarball")
        }
        return appURL
    }

    private func stripQuarantine(at url: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", url.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        // Ignore exit status — xattr -d is "success" even when the attr
        // wasn't set on macOS. Non-zero may be benign.
    }

    static let installedAppPath = "\(NSHomeDirectory())/Applications/StackNudge.app"
    // Pre-rename path; migrated away on launch via Bootstrap.migrateBundleNameIfNeeded.
    // Kept here so the Updater can detect a pre-1.7 install and delete its
    // bundle after the new one is in place.
    static let legacyInstalledAppPath = "\(NSHomeDirectory())/Applications/stack-nudge.app"

    // Move the existing bundle aside, move the new bundle into place. On
    // any error the swap reverts so the user isn't left with a half-
    // installed app. The .old bundle stays on disk until the next clean
    // shutdown — that's intentional, providing one extra layer of safety.
    private func atomicSwap(extractedAppURL: URL) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: Self.installedAppPath)
        let backup = URL(fileURLWithPath: Self.installedAppPath + ".old")

        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: backup)
        }
        let hadOriginal = fm.fileExists(atPath: target.path)
        if hadOriginal {
            try fm.moveItem(at: target, to: backup)
        }
        do {
            try fm.moveItem(at: extractedAppURL, to: target)
        } catch {
            // Best-effort restore.
            if hadOriginal {
                try? fm.moveItem(at: backup, to: target)
            }
            throw UpdateError.swapFailed(underlying: error)
        }

        // Post-swap: scrub the pre-1.7 bundle name if a migrating user
        // still has it sitting in ~/Applications. The plist already points
        // at the new path (Bootstrap.migrateBundleNameIfNeeded rewrote it
        // on first launch of the new bundle), so the old .app is just
        // dead weight at this point.
        let legacy = URL(fileURLWithPath: Self.legacyInstalledAppPath)
        if fm.fileExists(atPath: legacy.path) {
            try? fm.removeItem(at: legacy)
        }
    }

    // MARK: - Launchd

    private func kickstartLaunchd() throws {
        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k",
                          "gui/\(uid)/\(Bootstrap.appLabel)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            // Not fatal — the kickstart can fail if the agent isn't loaded
            // (e.g. fresh dev install). The new bundle is in place; user
            // can hit the hotkey to launch it manually next time.
            appendLog("launchctl kickstart exited \(task.terminationStatus) (non-fatal)")
        }
    }

    // MARK: - Status file

    private func writeStatusFile(state: String, version: String, error: String?) throws {
        var dict: [String: String] = ["state": state, "version": version]
        if let error { dict["error"] = error }
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: URL(fileURLWithPath: Self.statusPath))
    }

    // MARK: - State helpers

    private func setPhase(_ phase: UpdatePhase) {
        DispatchQueue.main.async { [weak self] in
            guard let nav = self?.nav else { return }
            if phase.step >= nav.updaterPhase.step {
                nav.updaterPhase = phase
            }
        }
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let nav = self?.nav else { return }
            let prefix = nav.updaterLog.isEmpty ? "" : "\n"
            nav.updaterLog += prefix + line
        }
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
                   ?? error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            self?.nav?.updaterPhase = .failed
            let prefix = self?.nav?.updaterLog.isEmpty == false ? "\n" : ""
            self?.nav?.updaterLog = (self?.nav?.updaterLog ?? "") + prefix
                + "ERROR: " + message
        }
        // Persist for the next-launch toast so a relaunched panel can
        // surface the failure (mostly defensive — we don't expect launchd
        // to restart us mid-update, but if it does, we want context).
        try? writeStatusFile(state: "failed", version: "", error: message)
    }

    private func scheduleAutoQuit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            NSApp.terminate(nil)
        }
    }

    private func currentArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        // Normalize: uname returns "arm64" or "x86_64" on macOS already.
        return raw
    }

    private func byteCount(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    // MARK: - Post-launch status pickup
}

// Pipeline errors surfaced into nav.updaterLog via fail(). Each case
// carries enough context to debug a CI artifact gone wrong without
// dropping into stderr.
enum UpdateError: LocalizedError {
    case releaseFetchFailed
    case malformedReleaseJSON(String)
    case noArtifactForArch(arch: String)
    case downloadHTTP(status: Int)
    case downloadSizeMismatch(expected: Int, got: Int)
    case checksumFetchFailed
    case checksumMismatch(expected: String, actual: String, assetName: String)
    case extractFailed(stderr: String)
    case swapFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .releaseFetchFailed:
            return "Couldn't reach GitHub Releases (and gh CLI fallback also failed)."
        case .malformedReleaseJSON(let detail):
            return "Release JSON didn't match expected shape: \(detail)"
        case .noArtifactForArch(let arch):
            return "No release artifact found for arch '\(arch)'. Expected something like stack-nudge-vX.Y.Z-macos-\(arch).tar.gz."
        case .downloadHTTP(let status):
            return "Download failed with HTTP status \(status)."
        case .downloadSizeMismatch(let expected, let got):
            return "Downloaded \(got) bytes, expected \(expected) bytes."
        case .checksumFetchFailed:
            return "Couldn't fetch the .sha256 sidecar for the release artifact."
        case .checksumMismatch(let expected, let actual, let assetName):
            return "Checksum mismatch for \(assetName). Expected \(expected), got \(actual)."
        case .extractFailed(let stderr):
            return "tar failed during extract: \(stderr)"
        case .swapFailed(let underlying):
            return "Failed to swap installed bundle: \(underlying.localizedDescription)"
        }
    }
}

// Wrapper extension so we can keep the existing class members + the
// post-launch status pickup in the original file structure.
extension Updater {

    // Called from PanelController.applicationDidFinishLaunching to read any
    // status file the runner left behind during the previous panel's death
    // and surface a result toast. The file is consumed on read.
    static func consumePostUpdateStatus() -> (state: String, version: String, error: String?)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        try? FileManager.default.removeItem(atPath: statusPath)
        let state = json["state"] ?? ""
        let version = json["version"] ?? ""
        let error = json["error"]
        return (state, version, error)
    }
}

// MARK: - Confirmation view

// Shown when the user clicks the "Update available" row before the install
// actually starts. Surfaces the release notes (or a graceful fallback when
// the API is unreachable) so the user knows what they're about to install.
struct UpdateConfirmView: View {

    @ObservedObject var nav: PanelNav
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    Divider().opacity(0.4)
                    notes
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(ThinScrollers())
            }

            PageFooter {
                FooterHint(label: "Update now", keys: ["⏎"], primary: true)
                FooterDivider()
                FooterHint(label: "Cancel", keys: ["Esc"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update stack-nudge")
                    .font(.headline)
                if let version = nav.updateAvailable {
                    Text("v\(version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var notes: some View {
        Text("Release notes")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
        if let body = nav.updateReleaseNotes, !body.isEmpty {
            MarkdownNotesView(source: body)
        } else {
            Text("Release notes unavailable. The update will clone the latest source from GitHub and reinstall in place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Post-update view

// Welcome-style screen shown automatically on the first launch after a
// successful update. Mirrors WelcomeView's layout (scrollable body + action
// bar) so the visual language stays consistent. Closes by Enter or "Got it"
// click, both of which set nav.mode = .events.
struct PostUpdateView: View {

    @ObservedObject var nav: PanelNav
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let notes = nav.postUpdateNotes, !notes.isEmpty {
                        Text("What's new")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.top, 4)
                        MarkdownNotesView(source: notes)
                    } else {
                        Text("Release notes unavailable. You can browse the full changelog on GitHub.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .background(ThinScrollers())
            }
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Updated to v\(nav.postUpdateVersion ?? "?")")
                    .font(.title3.weight(.semibold))
                Text("stack-nudge has been upgraded in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button {
                onDismiss()
            } label: {
                HStack(spacing: 6) {
                    Text("Got it").font(.subheadline.weight(.medium))
                    KeyCapView(symbol: "⏎")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.25))
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            ZStack {
                Color.primary.opacity(0.05)
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        )
    }
}

// MARK: - Markdown notes renderer

// Tiny line-by-line markdown renderer for release notes. Handles the four
// shapes release-please emits: ## / ### headings, bullet rows (* or -),
// blank lines as paragraph breaks, and paragraphs. Inline formatting
// (links, bold, italic, code) is passed through to SwiftUI's built-in
// AttributedString markdown parser via Text(.init(string)).
//
// We deliberately keep this minimal — no nested lists, no tables, no code
// blocks. release-please's auto-generated CHANGELOGs don't use them, and
// the panel is too narrow to render them well anyway.
struct MarkdownNotesView: View {

    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                render(line)
            }
        }
        .textSelection(.enabled)
    }

    private enum Line {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case paragraph(text: String)
        case blank
    }

    private var lines: [Line] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .blank }
            if trimmed.hasPrefix("### ") {
                return .heading(level: 3, text: String(trimmed.dropFirst(4)))
            }
            if trimmed.hasPrefix("## ") {
                return .heading(level: 2, text: String(trimmed.dropFirst(3)))
            }
            if trimmed.hasPrefix("# ") {
                return .heading(level: 1, text: String(trimmed.dropFirst(2)))
            }
            if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") {
                return .bullet(text: String(trimmed.dropFirst(2)))
            }
            return .paragraph(text: trimmed)
        }
    }

    @ViewBuilder
    private func render(_ line: Line) -> some View {
        switch line {
        case .blank:
            Color.clear.frame(height: 2)
        case .heading(let level, let text):
            Text(attributed(text))
                .font(headingFont(for: level))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 2 ? 4 : 0)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(attributed(text))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        case .paragraph(let text):
            Text(attributed(text))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Heading sizes scaled for the 420px-wide panel — h2 is "subheadline
    // bold", h3 is "footnote bold". Anything bigger looks shouty.
    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .headline
        case 2: return .subheadline.weight(.semibold)
        default: return .footnote.weight(.semibold)
        }
    }

    // Parse a single line's inline markdown (links, bold, italic, code)
    // into an AttributedString. Falls back to a plain string on error.
    private func attributed(_ source: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: source) {
            return attr
        }
        return AttributedString(source)
    }
}

// MARK: - Updating view

// Shown while install.sh is running. Top half: spinner + current phase
// label + step counter. Bottom half: a disclosure that reveals the raw
// install log (toggled via "Show output").
struct UpdatingView: View {

    @ObservedObject var nav: PanelNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                phaseHeader
                progressBar
                detailDisclosure
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            PageFooter {
                if nav.updaterPhase == .failed {
                    FooterHint(label: "Close", keys: ["Esc"])
                } else {
                    FooterHint(label: "Don't quit stack-nudge during update", keys: [])
                }
            }
        }
    }

    private var phaseHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if nav.updaterPhase == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            } else if nav.updaterPhase == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(nav.updaterPhase.label)
                .font(.headline)
            Spacer()
        }
    }

    private var progressBar: some View {
        let fraction = Double(nav.updaterPhase.step) / Double(UpdatePhase.totalSteps)
        return ProgressView(value: fraction)
            .tint(nav.updaterPhase == .failed ? .red : .accentColor)
    }

    @ViewBuilder
    private var detailDisclosure: some View {
        DisclosureGroup(isExpanded: $nav.updaterShowLog) {
            ScrollView {
                Text(nav.updaterLog.isEmpty ? "Waiting for output…" : nav.updaterLog)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        } label: {
            Text("Show output")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

