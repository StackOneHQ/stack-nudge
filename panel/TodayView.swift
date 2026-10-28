import SwiftUI

// The Today tab: today's meetings from the calendar watcher, in order, with
// the one in progress marked and the next one selected. ⏎ or a click opens
// the meeting link, or the calendar event when there is none.

enum TodayRows {
    enum Phase: Equatable { case past, now, upcoming }

    static func phase(_ meeting: Meeting, now: Date) -> Phase {
        if meeting.end <= now { return .past }
        return meeting.start <= now ? .now : .upcoming
    }

    // What the tab selects when it opens: the meeting in progress, else the
    // next one, else the last of the day.
    static func defaultIndex(_ meetings: [Meeting], now: Date) -> Int {
        meetings.firstIndex { phase($0, now: now) != .past } ?? max(0, meetings.count - 1)
    }

    static func timeRange(_ meeting: Meeting) -> String {
        let format = DateFormatter()
        format.timeStyle = .short
        format.dateStyle = .none
        return "\(format.string(from: meeting.start)) to \(format.string(from: meeting.end))"
    }
}

struct TodayView: View {
    @ObservedObject var nav: PanelNav

    var body: some View {
        VStack(spacing: 0) {
            content
            PageFooter {
                FooterHint(label: "Select", keys: ["↑↓"])
                FooterDivider()
                FooterHint(label: "Join / open", keys: ["⏎"], primary: true)
            }
        }
        .onAppear { nav.todaySelectedIndex = TodayRows.defaultIndex(nav.todaysMeetings, now: Date()) }
    }

    @ViewBuilder
    private var content: some View {
        let meetings = nav.todaysMeetings
        if nav.calendarAccess != .granted {
            VStack(spacing: 8) {
                Text("Calendar access is needed for today's meetings").font(.subheadline.weight(.medium))
                Text("Turn Calendar on in Settings and allow access when macOS asks.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Calendar settings") {
                    nav.settingsCategory = .calendar
                    nav.mode = .settings
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if meetings.isEmpty {
            Text("No meetings today")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Re-evaluated each minute so "Now" and the dimming move with the clock.
            TimelineView(.everyMinute) { timeline in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                                row(meeting, phase: TodayRows.phase(meeting, now: timeline.date),
                                    selected: index == nav.todaySelectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        nav.todaySelectedIndex = index
                                        nav.openSelectedMeeting()
                                    }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: nav.todaySelectedIndex) { proxy.scrollTo($0) }
                }
            }
        }
    }

    private func row(_ meeting: Meeting, phase: TodayRows.Phase, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(TodayRows.timeRange(meeting))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(meeting.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if phase == .now {
                        Text("Now")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(nav.theme.color)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(nav.theme.color.opacity(0.16)))
                    }
                    if !meeting.joinUrl.isEmpty {
                        Image(systemName: "video.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                let detail = [meeting.location, meeting.organizer].first { !$0.isEmpty } ?? meeting.calendar
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                let notes = meeting.notesSnippet(limit: 120)
                if !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? nav.theme.color.opacity(0.18) : Color.clear))
        .opacity(phase == .past ? 0.45 : 1)
        .contentShape(Rectangle())
    }
}
