import AppKit
import SwiftUI
import XCTest

@testable import StackNudgePanelCore

// The Events bar carries more hints than any other page, and #164 pushed it past
// the panel width — FooterHint is .fixedSize() inside a trailing-aligned row, so
// there was no shrink path and the leading hints ran off the panel. These pin the
// two halves of the fix: the shed decision itself, and the hint set the Events
// tab declares (including which entries are the sheddable ones).
final class ShedToFitLayoutTests: XCTestCase {

    // Hints 0…n-1 each 100pt wide, so widths in the assertions read as counts.
    // The shed order comes from the production comparator rather than a copy of
    // it — restating the rule here meant these passed whatever makeCache did.
    private func cache(_ shedOrders: [Int?], width: CGFloat = 100) -> ShedToFitLayout.Cache {
        ShedToFitLayout.Cache(
            sizes: shedOrders.map { _ in CGSize(width: width, height: 20) },
            shedOrder: ShedToFitLayout.shedSequence(of: shedOrders.map { $0 ?? .max }))
    }

    func test_shedSequence_lowestFirst_tiesTrailingMost() {
        XCTAssertEqual(ShedToFitLayout.shedSequence(of: [.max, 0, 1, .max]), [1, 2, 3, 0])
        // All unannotated: rightmost goes first, so the leading primary action
        // is the last thing standing.
        XCTAssertEqual(ShedToFitLayout.shedSequence(of: [.max, .max, .max]), [2, 1, 0])
        XCTAssertEqual(ShedToFitLayout.shedSequence(of: []), [])
    }

    func test_everythingFits_nothingIsShed() {
        let actual = ShedToFitLayout.keptIndices(width: 500, cache: cache([nil, 0, 1, nil]))
        XCTAssertEqual(actual, [0, 1, 2, 3])
    }

    func test_exactFit_nothingIsShed() {
        let actual = ShedToFitLayout.keptIndices(width: 400, cache: cache([nil, 0, 1, nil]))
        XCTAssertEqual(actual, [0, 1, 2, 3])
    }

    func test_shedsLowestOrderFirst() {
        // Room for three of four: index 1 (order 0) goes before index 2 (order 1).
        let actual = ShedToFitLayout.keptIndices(width: 300, cache: cache([nil, 0, 1, nil]))
        XCTAssertEqual(actual, [0, 2, 3])
    }

    func test_shedsInAscendingOrder_thenStops() {
        let actual = ShedToFitLayout.keptIndices(width: 200, cache: cache([nil, 0, 1, nil]))
        XCTAssertEqual(actual, [0, 3])
    }

    func test_unannotatedHintsShedTrailingMostFirst() {
        // Nothing is annotated, so the bar gives up its rightmost hint rather
        // than the leading primary action.
        let actual = ShedToFitLayout.keptIndices(width: 200, cache: cache([nil, nil, nil]))
        XCTAssertEqual(actual, [0, 1])
    }

    func test_neverEmptiesTheBar() {
        // A truncated hint still tells the user something; an empty bar doesn't.
        let actual = ShedToFitLayout.keptIndices(width: 0, cache: cache([nil, 0, 1]))
        XCTAssertEqual(actual.count, 1)
    }

    func test_singleHint_isKeptEvenWhenItCannotFit() {
        let actual = ShedToFitLayout.keptIndices(width: 10, cache: cache([nil]))
        XCTAssertEqual(actual, [0])
    }

    func test_widthsAreSummedFromMeasuredSizes_notHintCount() {
        // One wide hint and two narrow ones: shedding the wide one alone is
        // enough, so the narrow pair both survive.
        let sizes = [CGSize(width: 300, height: 20),
                     CGSize(width: 40, height: 20),
                     CGSize(width: 40, height: 20)]
        let cache = ShedToFitLayout.Cache(sizes: sizes, shedOrder: [0, 2, 1])
        XCTAssertEqual(ShedToFitLayout.keptIndices(width: 100, cache: cache), [1, 2])
    }
}

// The one hop in the shed mechanism that rests on SwiftUI rather than
// arithmetic: a spec's shedOrder has to survive FooterHintRow applying
// .footerShedOrder() inside its own body and arrive at the parent Layout. If it
// ever stops arriving, every hint reads .max and shedding quietly degrades to
// trailing-most-first — the bar still fits and the layout still looks right,
// you just lose the wrong hint. Nothing else here would notice.
@MainActor
final class FooterShedOrderPropagationTests: XCTestCase {

    // Reads the annotation back off a real layout pass.
    private struct Probe: Layout {
        let sink: ([Int]) -> Void

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            sink(subviews.map { $0[FooterShedOrderKey.self] })
            return CGSize(width: 100, height: 20)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) {}
    }

    func test_shedOrderReachesTheLayoutThroughFooterHintRow() {
        // NSHostingView needs the shared app to exist; harmless if it already does.
        _ = NSApplication.shared
        var captured: [Int] = []
        let host = NSHostingView(rootView: Probe(sink: { captured = $0 }) {
            FooterHintRow(spec: FooterHintSpec(label: "first", keys: ["1"], shedOrder: 7))
            FooterHintRow(spec: FooterHintSpec(label: "second", keys: ["2"]))
            FooterHintRow(spec: FooterHintSpec(label: "third", keys: ["3"], shedOrder: 2))
        })
        _ = host.fittingSize   // forces the layout pass

        XCTAssertEqual(captured, [7, .max, 2])
        // And the rule the layout applies to them: 2 goes first, then 7, then
        // the unannotated one.
        XCTAssertEqual(ShedToFitLayout.shedSequence(of: captured), [2, 0, 1])
    }
}

// The bar the Events tab declares, per pane and per selection state.
final class EventsFooterHintsTests: XCTestCase {

    private func hints(pane: EventsPane = .live,
                       filterFocused: Bool = false,
                       filterQuery: String = "",
                       liveQueueEmpty: Bool = false,
                       primaryAction: String? = "Open editor",
                       dismissLabel: String = "Dismiss",
                       snoozeEnabled: Bool = false,
                       muted: Bool = false) -> [FooterHintSpec] {
        PanelContentView.eventsFooterHints(
            pane: pane, filterFocused: filterFocused, filterQuery: filterQuery,
            liveQueueEmpty: liveQueueEmpty, primaryAction: primaryAction,
            dismissLabel: dismissLabel, snoozeEnabled: snoozeEnabled, muted: muted)
    }

    func test_liveQueue_advertisesHistoryOnH() {
        XCTAssertEqual(hints().first(where: { $0.label == "History" })?.keys, ["H"])
        XCTAssertEqual(hints(liveQueueEmpty: true).first(where: { $0.label == "History" })?.keys, ["H"])
    }

    func test_liveQueue_selectCarriesBothArrowShortcuts() {
        // ⌘↑↓ rides along on Select rather than paying for a "Top/Bottom" label
        // of its own — that label was the width this bar couldn't afford, and
        // shedding the hint instead would have hidden an existing shortcut at
        // the default panel width to make room for the new History one.
        XCTAssertEqual(hints().first(where: { $0.label == "Select" })?.keys, ["↑↓", "⌘↑↓"])
        XCTAssertFalse(hints().contains { $0.label == "Top/Bottom" })
    }

    func test_onlySnoozeIsSheddable() {
        let sheddable = hints().filter { $0.shedOrder != nil }
        XCTAssertEqual(sheddable.map(\.label), ["Snooze"])
        XCTAssertEqual(sheddable.map(\.shedOrder), [0])
    }

    func test_actionsAndShortcutsAreNeverSheddable() {
        let unsheddable = hints().filter { $0.shedOrder == nil }.map(\.label)
        XCTAssertEqual(unsheddable, ["Open editor", "Select", "Dismiss", "Mute", "History", "Hide"])
    }

    func test_primaryActionIsFirstAndMarkedPrimary() {
        let actual = hints(primaryAction: "Approve")
        XCTAssertEqual(actual.first?.label, "Approve")
        XCTAssertTrue(actual.first?.primary == true)
    }

    func test_noSelection_dropsThePrimaryAction() {
        let actual = hints(primaryAction: nil)
        XCTAssertEqual(actual.first?.label, "Select")
        XCTAssertFalse(actual.contains { $0.primary })
    }

    func test_mutedSwapsMuteForResume() {
        XCTAssertTrue(hints(muted: true).contains { $0.label == "Resume" && $0.keys == ["M"] })
        XCTAssertFalse(hints(muted: true).contains { $0.label == "Mute" })
    }

    func test_snoozeIsDimmedWhenTheRowIsNotSnoozable() {
        XCTAssertTrue(hints(snoozeEnabled: false).first { $0.label == "Snooze" }?.dimmed == true)
        XCTAssertTrue(hints(snoozeEnabled: true).first { $0.label == "Snooze" }?.dimmed == false)
    }

    func test_emptyQueue_keepsMuteAndHistory() {
        let actual = hints(liveQueueEmpty: true).map(\.label)
        XCTAssertEqual(actual, ["Mute", "History", "Hide"])
    }

    func test_historyUnfocused_advertisesRowNavigationFilterAndOneExit() {
        // One exit, not two. Esc steps back to the live queue from here; it
        // doesn't hide the panel, so a "Hide Esc" hint alongside "Back" was a lie.
        let actual = hints(pane: .history)
        XCTAssertEqual(actual.map(\.label), ["Select", "Filter", "Back"])
        XCTAssertEqual(actual[0].keys, ["↑↓", "⌘↑↓"])
        XCTAssertEqual(actual[1].keys, ["/"])
        XCTAssertEqual(actual[2].keys, ["Esc"])
        XCTAssertFalse(actual.contains { $0.label == "Hide" })
    }

    func test_historyFocused_offersReturnToTheRowsAndEscape() {
        // The field editor consumes ← and ↑↓ as caret moves once it has focus,
        // so advertising them there would be a lie. ⏎ hands the keyboard back to
        // the rows without clearing the filter; Esc clears it, then steps back.
        let empty = hints(pane: .history, filterFocused: true)
        XCTAssertEqual(empty.map(\.label), ["Rows", "Back"])
        XCTAssertEqual(empty[0].keys, ["⏎"])
        XCTAssertEqual(empty[1].keys, ["Esc"])

        let filtered = hints(pane: .history, filterFocused: true, filterQuery: "eng")
        XCTAssertEqual(filtered.map(\.label), ["Rows", "Clear filter"])
    }
}

// Where each keystroke goes in the history pane. Raw virtual key codes, since
// the panel's KeyCode table is private: 53 Esc, 123 ←, 124 →, 44 /, 0 "a".
final class HistoryKeyActionTests: XCTestCase {

    private func action(_ keyCode: UInt16,
                        _ characters: String? = nil,
                        filterIsEmpty: Bool = true) -> PanelController.HistoryKeyAction {
        PanelController.historyKeyAction(keyCode: keyCode,
                                         characters: characters,
                                         filterIsEmpty: filterIsEmpty)
    }

    func test_horizontalArrowsDoNothing() {
        // ←/→ no longer move between panes: Esc is the single way out, so the
        // footer doesn't have to advertise both a Back and a Hide. They must
        // still be swallowed rather than reach the filter (their private-use
        // codepoints once got seeded into it as invisible junk).
        XCTAssertEqual(action(123, "\u{F702}"), .swallow)
        XCTAssertEqual(action(123, "\u{F702}", filterIsEmpty: false), .swallow)
        XCTAssertEqual(action(124, "\u{F703}"), .swallow)
    }

    func test_escapeIsTheOnlyWayOut() {
        XCTAssertEqual(action(53, "\u{1B}", filterIsEmpty: true), .back)
    }

    func test_verticalArrowsMoveTheRowSelection() {
        XCTAssertEqual(action(126, "\u{F700}"), .moveSelection(-1))
        XCTAssertEqual(action(125, "\u{F701}"), .moveSelection(1))
    }

    func test_escapeClearsTheFilterThenStepsBack() {
        XCTAssertEqual(action(53, "\u{1B}", filterIsEmpty: false), .clearFilter)
        XCTAssertEqual(action(53, "\u{1B}", filterIsEmpty: true), .back)
    }

    func test_slashFocusesTheFilterWithoutTypingIntoIt() {
        XCTAssertEqual(action(44, "/"), .focusFilter)
    }

    func test_printableCharacterSeedsTheFilter() {
        XCTAssertEqual(action(0, "a"), .appendToFilter("a"))
        XCTAssertEqual(action(0, "É"), .appendToFilter("É"))
    }

    func test_navigationKeysAreSwallowedRatherThanSeeded() {
        // Key code 0 here: these are the private-use characters arriving under
        // some *other* key code, which must never be seeded into the filter.
        for scalar in [0xF700, 0xF701, 0xF704, 0xF729, 0xF72C] {
            XCTAssertEqual(action(0, String(UnicodeScalar(scalar)!)), .swallow,
                           "expected U+\(String(scalar, radix: 16)) to be swallowed")
        }
    }

    func test_noCharactersIsSwallowed() {
        XCTAssertEqual(action(0, nil), .swallow)
    }
}

// Moving the selection over the rows the history pane is actually showing.
@MainActor
final class HistorySelectionTests: XCTestCase {

    private func record(_ message: String, at: TimeInterval) -> EventRecord {
        EventRecord(at: Date(timeIntervalSince1970: at), agent: "claude", kind: "stop",
                    title: "Done", message: message, project: "/work/stack-nudge", session: nil)
    }

    private func nav(_ messages: [String], query: String = "") -> PanelNav {
        let nav = PanelNav()
        nav.historyRecords = messages.enumerated().map { record($1, at: TimeInterval($0)) }
        nav.historyQuery = query
        return nav
    }

    func test_fromNoSelection_eitherDirectionLandsOnTheNewestRow() {
        // Not "index 0 then step": that made the first ↓ skip the top row.
        for delta in [1, -1] {
            let subject = nav(["one", "two", "three"])
            subject.moveHistorySelection(delta)
            XCTAssertEqual(subject.historySelectedID, subject.filteredHistory.first?.id,
                           "delta \(delta) should land on the newest row")
        }
    }

    func test_movesOneRowAtATime() {
        let subject = nav(["one", "two", "three"])
        subject.historySelectedID = subject.filteredHistory[0].id
        subject.moveHistorySelection(1)
        XCTAssertEqual(subject.historySelectedID, subject.filteredHistory[1].id)
        subject.moveHistorySelection(-1)
        XCTAssertEqual(subject.historySelectedID, subject.filteredHistory[0].id)
    }

    func test_clampsAtBothEndsRatherThanWrapping() {
        let subject = nav(["one", "two"])
        subject.historySelectedID = subject.filteredHistory[0].id
        subject.moveHistorySelection(-1)
        XCTAssertEqual(subject.historySelectedID, subject.filteredHistory[0].id)
        subject.moveHistorySelection(1)
        subject.moveHistorySelection(1)
        XCTAssertEqual(subject.historySelectedID, subject.filteredHistory[1].id)
    }

    func test_jumpsToFirstAndLast() {
        let subject = nav(["one", "two", "three"])
        subject.jumpHistorySelection(toLast: true)
        XCTAssertEqual(subject.historySelectedID, subject.filteredHistory.last?.id)
        subject.jumpHistorySelection(toLast: false)
        XCTAssertEqual(subject.historySelectedID, subject.filteredHistory.first?.id)
    }

    func test_movesOverTheFilteredRowsOnly() {
        // ⌘↓ has to land on the last *visible* row, not the last recorded one.
        let subject = nav(["alpha", "beta", "alpha again"], query: "alpha")
        XCTAssertEqual(subject.filteredHistory.count, 2)
        subject.jumpHistorySelection(toLast: true)
        XCTAssertEqual(subject.historySelectedID, subject.filteredHistory[1].id)
        XCTAssertFalse(subject.filteredHistory.contains { $0.message == "beta" })
    }

    func test_aSelectionTheFilterDroppedRestartsFromTheTop() {
        let subject = nav(["alpha", "beta"])
        subject.historySelectedID = subject.filteredHistory.first { $0.message == "beta" }?.id
        subject.historyQuery = "alpha"
        subject.moveHistorySelection(1)
        XCTAssertEqual(subject.historySelectedID, subject.filteredHistory.first?.id)
    }

    func test_emptyListIsANoOp() {
        let subject = nav([])
        subject.moveHistorySelection(1)
        subject.jumpHistorySelection(toLast: true)
        XCTAssertNil(subject.historySelectedID)
    }
}

// Which keystrokes start filtering history rather than being swallowed.
final class HistoryFilterInputTests: XCTestCase {

    func test_acceptsVisibleCharacters() {
        for input in ["a", "Z", "7", "-", "/", "_", ".", "é", "日"] {
            XCTAssertTrue(PanelController.isFilterInput(input), "expected \(input) to filter")
        }
    }

    func test_rejectsControlCharacters() {
        for input in ["\u{1B}", "\u{7F}", "\r", "\n", "\t"] {
            XCTAssertFalse(PanelController.isFilterInput(input), "expected \(input) to be ignored")
        }
    }

    func test_rejectsAppKitFunctionKeys() {
        // AppKit reports these as private-use codepoints, which are neither
        // control characters nor illegal ones. Accepting them put an invisible
        // U+F703 in the filter on a → key repeat and stole the field's focus,
        // which is what broke ← as the way back to the live queue.
        let names = ["up": 0xF700, "down": 0xF701, "left": 0xF702, "right": 0xF703,
                     "F1": 0xF704, "home": 0xF729, "pageUp": 0xF72C]
        for (name, scalar) in names {
            let input = String(UnicodeScalar(scalar)!)
            XCTAssertFalse(PanelController.isFilterInput(input), "expected \(name) to be ignored")
        }
    }

    func test_acceptsSpaceSoMultiWordFiltersWork() {
        XCTAssertTrue(PanelController.isFilterInput(" "))
    }

    func test_rejectsEmptyAndMultiCharacterInput() {
        XCTAssertFalse(PanelController.isFilterInput(""))
        XCTAssertFalse(PanelController.isFilterInput("ab"))
    }
}
