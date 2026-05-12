import AppKit
import Foundation
import SwiftUI

// Phase of the auto-update flow. Parsed from `# STAGE: …` markers written
// by install.sh into the runner log file. Drives the progress UI in
// UpdatingView.
enum UpdatePhase: String {
    case idle
    case cloning
    case building
    case venv
    case launchd
    case hooks
    case done
    case failed
}

extension UpdatePhase {
    // Human-readable label shown alongside the spinner.
    var label: String {
        switch self {
        case .idle:     return "Preparing…"
        case .cloning:  return "Cloning repository…"
        case .building: return "Building app…"
        case .venv:     return "Setting up voice engine…"
        case .launchd:  return "Registering background agents…"
        case .hooks:    return "Wiring agent hooks…"
        case .done:     return "Restarting stack-nudge…"
        case .failed:   return "Update failed"
        }
    }

    // Ordinal position used to render the progress bar. `failed` shares the
    // last fillable slot so the bar doesn't suddenly empty on failure.
    var step: Int {
        switch self {
        case .idle:     return 0
        case .cloning:  return 1
        case .building: return 2
        case .venv:     return 3
        case .launchd:  return 4
        case .hooks:    return 5
        case .done, .failed: return 6
        }
    }

    static let totalSteps: Int = 6
}

// Drives the click-to-update flow. Spawns install.sh in a detached session
// (via Python `os.setsid()`) so it survives the pkill install.sh runs on the
// running panel mid-flight. Tails the runner log file for live phase + log
// updates that the UI binds to.
//
// On completion the runner writes /tmp/stack-nudge-update-status.json so
// the next panel instance (started by launchctl after the swap) can pick up
// where the dying instance left off and show a confirmation toast.
final class Updater {

    // GitHub HTTPS clone URL. SSH (`git@github.com:…`) would require key
    // setup; HTTPS works for any user with credential-helper auth (macOS
    // keychain or gh CLI integration), which is the org-member default.
    static let cloneURL = "https://github.com/StackOneHQ/stack-nudge.git"

    static let logPath    = "/tmp/stack-nudge-update.log"
    static let statusPath = "/tmp/stack-nudge-update-status.json"

    private weak var nav: PanelNav?
    private var tailHandle: DispatchSourceFileSystemObject?
    private var tailFD: Int32 = -1
    private var tailOffset: off_t = 0
    private var logBuffer = ""

    init(nav: PanelNav) {
        self.nav = nav
    }

    // Kicks off the install in a detached session. Returns immediately —
    // progress flows back to the panel via nav.updaterPhase / nav.updaterLog.
    // The runner survives our death (when install.sh pkills us) because of
    // setsid; launchctl reload brings a fresh panel up afterwards.
    func run() {
        guard let nav else { return }
        DispatchQueue.main.async {
            nav.updaterPhase = .idle
            nav.updaterLog = ""
            nav.mode = .updating
        }

        // Clean slate: any prior log + status file from a previous run.
        try? FileManager.default.removeItem(atPath: Self.logPath)
        try? FileManager.default.removeItem(atPath: Self.statusPath)
        FileManager.default.createFile(atPath: Self.logPath, contents: nil)

        let runnerPath = "/tmp/stack-nudge-update-runner.sh"
        let runnerScript = Self.makeRunnerScript()
        try? runnerScript.write(toFile: runnerPath,
                                atomically: true, encoding: .utf8)
        _ = chmod(runnerPath, 0o755)

        startTailing()

        // Spawn the runner detached via Python's os.setsid + execvp so the
        // child process gets its own session and won't be torn down when
        // launchd unloads the panel job mid-update.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Fork before setsid: Foundation.Process places the spawned child
        // in its own process group as the leader, so calling setsid() on
        // python directly raises EPERM. We fork once; the child (not a
        // pgroup leader) can setsid + exec bash cleanly while the parent
        // exits, fully detaching the runner from our session.
        task.arguments = [
            "python3", "-c",
            """
            import os, sys
            pid = os.fork()
            if pid == 0:
                os.setsid()
                os.execvp('bash', ['bash'] + sys.argv[1:])
            else:
                os._exit(0)
            """,
            runnerPath,
        ]
        task.standardInput  = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        // Diagnostic: capture stderr to a file so silent Python errors
        // (e.g. PermissionError from setsid()) become visible. Inspect with
        // `cat /tmp/stack-nudge-update-spawn.err` after a failed run.
        let stderrPath = "/tmp/stack-nudge-update-spawn.err"
        try? FileManager.default.removeItem(atPath: stderrPath)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        if let stderrHandle = FileHandle(forWritingAtPath: stderrPath) {
            task.standardError = stderrHandle
        } else {
            task.standardError = FileHandle.nullDevice
        }
        do {
            try task.run()
        } catch {
            DispatchQueue.main.async {
                nav.updaterPhase = .failed
                nav.updaterLog = "Failed to start updater: \(error.localizedDescription)"
            }
        }
    }

    // Build the bash runner. It clones the repo to a fresh tmp dir, runs
    // install.sh, and writes a JSON status file at the end. Output and STAGE
    // markers go through tee so we get both file persistence and live-tail
    // visibility from the panel.
    private static func makeRunnerScript() -> String {
        let cloneURL = Self.cloneURL
        let logPath = Self.logPath
        let statusPath = Self.statusPath
        return """
        #!/usr/bin/env bash
        # stack-nudge auto-updater runner. Spawned in a detached session by
        # Updater.swift; survives the pkill install.sh runs on the panel.
        set -o pipefail
        LOG=\(logPath)
        STATUS=\(statusPath)
        WORK=$(mktemp -d -t stack-nudge-update)
        trap 'rm -rf "$WORK"' EXIT

        write_status() {
          local state="$1" version="$2" error_message="$3"
          python3 - "$STATUS" "$state" "$version" "$error_message" <<'PY'
        import json, sys
        path, state, version, err = sys.argv[1:5]
        d = {"state": state, "version": version}
        if err:
            d["error"] = err
        with open(path, "w") as f:
            json.dump(d, f)
        PY
        }

        run() {
          echo "# STAGE: cloning"
          echo "Cloning \(cloneURL) ..."
          git clone --depth 1 \(cloneURL) "$WORK" 2>&1 || return 1
          local version
          version=$(git -C "$WORK" describe --tags --abbrev=0 2>/dev/null || true)
          echo "Cloned $(git -C "$WORK" rev-parse --short HEAD) (tag: ${version:-none})"
          cd "$WORK"
          bash ./install.sh 2>&1 || return 1
          write_status "success" "${version#v}" ""
          return 0
        }

        run > "$LOG" 2>&1
        rc=$?
        if [[ $rc -ne 0 ]]; then
          # install.sh's failure already in the log; record the failed state
          # for the post-swap panel to surface.
          write_status "failed" "" "exit code $rc"
        fi
        exit $rc

        """
    }

    // MARK: - Live log tailing

    // Watches the runner log for writes and parses any new content. Each
    // STAGE marker advances nav.updaterPhase; the full content backs the
    // expandable "Show output" detail panel.
    //
    // Uses DispatchSource for filesystem events instead of polling so we
    // get near-instant UI updates. Safe to call multiple times — any prior
    // tail is torn down and offset is reset, so a re-triggered run() picks
    // up from byte 0 of the fresh log file.
    private func startTailing() {
        // Tear down any prior tail before opening a fresh one. Without this,
        // a second run() call would inherit the previous run's offset and
        // skip all output (since the truncate makes the new file smaller
        // than the saved offset).
        tailHandle?.cancel()
        tailHandle = nil
        if tailFD >= 0 { close(tailFD); tailFD = -1 }
        tailOffset = 0
        logBuffer = ""

        tailFD = open(Self.logPath, O_RDONLY)
        guard tailFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: tailFD,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.consume() }
        source.resume()
        tailHandle = source

        // Read whatever's already there in case the first event fires
        // after install.sh has already written.
        consume()
    }

    private func consume() {
        guard tailFD >= 0 else { return }
        let size = lseek(tailFD, 0, SEEK_END)
        guard size > tailOffset else { return }
        let toRead = Int(size - tailOffset)
        _ = lseek(tailFD, tailOffset, SEEK_SET)
        var data = Data(count: toRead)
        let bytesRead = data.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return read(tailFD, base, toRead)
        }
        if bytesRead > 0 {
            tailOffset += off_t(bytesRead)
            if let chunk = String(data: data.prefix(bytesRead), encoding: .utf8) {
                logBuffer += chunk
                processChunk(chunk)
            }
        }
    }

    // Parse STAGE markers (preferred) and natural install.sh output lines
    // (fallback) out of newly-arrived log content. The fallback path keeps
    // the progress UI accurate when the cloned install.sh is from an older
    // release that predates the STAGE markers — otherwise the UI would
    // stick on .cloning until the runner finished.
    private func processChunk(_ chunk: String) {
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# STAGE: ") {
                let name = String(trimmed.dropFirst("# STAGE: ".count))
                if let phase = UpdatePhase(rawValue: name) { advance(to: phase) }
            } else if let phase = Self.heuristicPhase(for: trimmed) {
                advance(to: phase)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nav?.updaterLog = self.logBuffer
        }
    }

    // Only ever moves forward — guards against an out-of-order line bumping
    // the phase backwards (e.g. seeing the runner's older "Cloning..." echo
    // after install.sh has already advanced us). When .done is reached for
    // the first time, schedules a graceful self-quit so the freshly-installed
    // bundle (relaunched by launchd) takes over without two panels lingering.
    private func advance(to phase: UpdatePhase) {
        DispatchQueue.main.async { [weak self] in
            guard let nav = self?.nav else { return }
            guard phase.step >= nav.updaterPhase.step else { return }
            let firstTimeReachingDone = (phase == .done && nav.updaterPhase != .done)
            nav.updaterPhase = phase
            if firstTimeReachingDone {
                self?.scheduleAutoQuit()
            }
        }
    }

    // Quit ~2s after the install finishes so the user can read the "Done"
    // confirmation before the panel disappears. install.sh's launchctl
    // reload will then own the newly-installed binary's lifecycle.
    private func scheduleAutoQuit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            NSApp.terminate(nil)
        }
    }

    // Recognise canonical install.sh output lines as phase markers. Order
    // matters: more specific matches first so "Done!" doesn't get classified
    // as something else. Used only when explicit STAGE markers are absent.
    private static func heuristicPhase(for line: String) -> UpdatePhase? {
        if line.hasPrefix("Done!") { return .done }
        if line.contains("registered as launchd agent") { return .launchd }
        if line.hasPrefix("Setting up voice engine") { return .venv }
        if line.hasPrefix("Building stack-nudge") { return .building }
        if line.hasPrefix("Installing stack-nudge") { return .building }
        if line.hasPrefix("Detected ") { return .hooks }
        return nil
    }

    // MARK: - Post-launch status pickup

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
                FooterHint(label: "Cancel", keys: ["esc"])
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
                    FooterHint(label: "Close", keys: ["esc"])
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

