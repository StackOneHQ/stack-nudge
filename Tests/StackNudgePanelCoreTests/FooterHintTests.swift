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

// Where each keystroke goes on the extensions browser. Raw virtual key codes,
// since the panel's KeyCode table is private: 53 Esc, 44 /, 126/125 ↑↓,
// 36 Return, 15 "r", 123/124 ←→, 49 Space.
//
// This table exists because the first version of this page's key handling was
// wrong in a way nothing could see. It focused the search field on arrival and
// then made the handler fall through for unrecognised keys so letters could
// "reach SwiftUI" — but a focused field is first responder, and
// FloatingPanel.keyDown only fires for what the first responder declines, so
// letters never reached the handler at all. Nothing needed releasing; all that
// changed was that Esc, ↑↓ and ⏎ stopped working while the footer went on
// advertising them.
final class ExtensionsKeyActionTests: XCTestCase {

    private func action(_ keyCode: UInt16,
                        _ characters: String? = nil,
                        queryIsEmpty: Bool = true) -> PanelController.ExtensionsKeyAction {
        PanelController.extensionsKeyAction(keyCode: keyCode,
                                            characters: characters,
                                            queryIsEmpty: queryIsEmpty)
    }

    // Two steps, like the history filter: clear what you typed, then leave.
    func test_escapeClearsTheQueryBeforeItStepsBack() {
        XCTAssertEqual(action(53, "\u{1B}", queryIsEmpty: true), .back)
        XCTAssertEqual(action(53, "\u{1B}", queryIsEmpty: false), .clearQuery)
    }

    func test_slashHandsOverToTheField() {
        XCTAssertEqual(action(44, "/"), .focusSearch)
    }

    func test_verticalArrowsMoveTheSelection() {
        XCTAssertEqual(action(126, "\u{F700}"), .moveSelection(-1))
        XCTAssertEqual(action(125, "\u{F701}"), .moveSelection(1))
    }

    func test_returnActsOnTheSelectedRow() {
        XCTAssertEqual(action(36, "\r"), .activate)
        XCTAssertEqual(action(76, "\u{3}"), .activate)
    }

    // Type-to-search costs no extra keystroke despite the field not grabbing
    // focus on arrival.
    func test_aPrintableCharacterSeedsTheQuery() {
        XCTAssertEqual(action(15, "r"), .appendToQuery("r"))
        XCTAssertEqual(action(49, " "), .appendToQuery(" "))
        XCTAssertEqual(action(0, "é"), .appendToQuery("é"))
    }

    // AppKit reports arrows and function keys as private-use scalars, which are
    // neither control characters nor illegal ones — a "not a control character"
    // test seeds the query with invisible junk and hands the field focus off
    // the back of it.
    func test_arrowsAndFunctionKeysAreSwallowedRatherThanTyped() {
        XCTAssertEqual(action(123, "\u{F702}"), .swallow)
        XCTAssertEqual(action(124, "\u{F703}"), .swallow)
        XCTAssertEqual(action(122, "\u{F704}"), .swallow)
        XCTAssertEqual(action(48, "\t"), .swallow)
        XCTAssertEqual(action(99, nil), .swallow)
    }

    // Nothing falls through to the tab shortcuts below this branch: they act on
    // a list this page isn't showing.
    func test_everyKeyIsAccountedFor() {
        for code in UInt16(0)...UInt16(130) {
            _ = action(code, nil)
        }
    }
}

// Where each keystroke goes on an extension's own configuration form, and what
// its footer promises at each of the two levels. Raw virtual key codes, since
// the panel's KeyCode table is private: 53 Esc, 126/125 up/down, 36 Return,
// 76 numpad Enter, 48 Tab, 123/124 left/right, 1 "s", 51 delete.
//
// The page is a list of text fields, and a focused field is first responder, so
// it takes every key before FloatingPanel.keyDown runs. That is why the
// traversal lives one level above the fields: the form used to own Esc and
// nothing else, which left it reachable only with the mouse or with Tab while
// the footer advertised Return.
final class ExtensionConfigKeyActionTests: XCTestCase {

    private func action(_ keyCode: UInt16,
                        hasFields: Bool = true) -> PanelController.ExtensionConfigKeyAction {
        PanelController.extensionConfigKeyAction(keyCode: keyCode, hasFields: hasFields)
    }

    func test_escapeStepsBackOffThePage() {
        XCTAssertEqual(action(53), .back)
    }

    func test_verticalArrowsMoveBetweenFields() {
        XCTAssertEqual(action(126), .moveSelection(-1))
        XCTAssertEqual(action(125), .moveSelection(1))
    }

    // Return and Tab are both how a macOS form is entered, and at this level
    // nothing else claims either of them.
    func test_returnAndTabHandTheSelectedFieldFocus() {
        XCTAssertEqual(action(36), .editSelectedField)
        XCTAssertEqual(action(76), .editSelectedField)
        XCTAssertEqual(action(48), .editSelectedField)
    }

    // An extension declaring no config keys is every refused one and every
    // extension as plain as `system`. There is nothing to hand focus to, and
    // setting focus to nothing reads as a keystroke that lost the selection.
    func test_withNoFieldsThereIsNothingToFocus() {
        XCTAssertEqual(action(36, hasFields: false), .swallow)
        XCTAssertEqual(action(48, hasFields: false), .swallow)
        // Moving is still answered here rather than passed on; the model makes
        // it a no-op. Swallowing it in one place and no-opping it in the other
        // would be two rules for one key.
        XCTAssertEqual(action(126, hasFields: false), .moveSelection(-1))
    }

    func test_horizontalArrowsDoNothingOnAForm() {
        XCTAssertEqual(action(123), .swallow)
        XCTAssertEqual(action(124), .swallow)
    }

    // Nothing falls through to the Events bindings, which map Return to
    // approving a permission prompt on a tab this page isn't showing.
    func test_everyKeyIsAccountedFor() {
        for code in UInt16(0)...UInt16(130) {
            _ = action(code)
            _ = action(code, hasFields: false)
        }
    }
}

// The same form's footer. Each hint has to be true at the level it appears on:
// the bar used to advertise Save on a page where Return did nothing until a
// field had been clicked, and on extensions that declare no fields at all.
final class ExtensionConfigFooterTests: XCTestCase {

    private func hints(keyCount: Int, editing: Bool, valid: Bool = true) -> [FooterHintSpec] {
        ExtensionConfigView.footerHints(keyCount: keyCount, editing: editing, valid: valid)
    }

    private func labels(_ specs: [FooterHintSpec]) -> [String] { specs.map(\.label) }

    // Every installed extension opens a page, because that is where Remove
    // lives. One declaring nothing has no field to edit, move between or save.
    func test_noKeys_offersOnlyBackAndRemove() {
        XCTAssertEqual(labels(hints(keyCount: 0, editing: false)), ["Back", "Remove"])
    }

    // One field is somewhere to go into, but nowhere to move to.
    func test_oneKey_offersEditAndSaveButNotMove() {
        XCTAssertEqual(labels(hints(keyCount: 1, editing: false)),
                       ["Edit", "Save", "Back", "Remove"])
    }

    func test_severalKeys_advertiseTheTraversal() {
        let specs = hints(keyCount: 2, editing: false)
        XCTAssertEqual(labels(specs), ["Edit", "Move", "Save", "Back", "Remove"])
        // Both the step and the jump, riding on one label rather than paying
        // for a second, exactly as the Events bar carries its own.
        XCTAssertEqual(specs.first { $0.label == "Move" }?.keys, ["↑↓", "⌘↑↓"])
    }

    // Inside a field the page has given the keyboard away: Return saves,
    // Esc hands it back rather than leaving the page.
    func test_editing_namesWhatTheKeysDoFromInsideAField() {
        XCTAssertEqual(labels(hints(keyCount: 2, editing: true)),
                       ["Save", "Next field", "Done", "Remove"])
    }

    func test_editing_dropsTabWithOnlyOneField() {
        XCTAssertEqual(labels(hints(keyCount: 1, editing: true)), ["Save", "Done", "Remove"])
    }

    // ⌘⌫ is a field-editor binding (deleteToBeginningOfLine), so a focused
    // field takes it before the panel sees it. It dims rather than
    // disappearing: the bar must not reflow as focus moves.
    func test_removeDimsWhileEditingRatherThanVanishing() {
        let idle = hints(keyCount: 1, editing: false).first { $0.label == "Remove" }
        let busy = hints(keyCount: 1, editing: true).first { $0.label == "Remove" }
        XCTAssertEqual(idle?.dimmed, false)
        XCTAssertEqual(busy?.dimmed, true)
    }

    // ⌘S is not a field-editor binding, so unlike ⌘⌫ it works from inside a
    // field too; at that level Return is the shorter way to the same thing.
    func test_saveIsReachableAtBothLevels() {
        XCTAssertEqual(hints(keyCount: 1, editing: false).first { $0.label == "Save" }?.keys, ["⌘S"])
        XCTAssertEqual(hints(keyCount: 1, editing: true).first { $0.label == "Save" }?.keys, ["⏎"])
    }

    // A value the form will refuse gets the same answer from the bar that it
    // gets from the button, which disables itself. Dimmed rather than dropped:
    // the hint is real, it just does not apply to what is typed.
    func test_saveDimsOnAValueTheFormWillRefuse() {
        for editing in [true, false] {
            let spec = hints(keyCount: 1, editing: editing, valid: false)
                .first { $0.label == "Save" }
            XCTAssertEqual(spec?.dimmed, true, "editing: \(editing)")
        }
    }

    // Nothing on this bar may be dropped before the two that navigate it.
    func test_backAndRemoveAreNeverSheddable() {
        for editing in [true, false] {
            for spec in hints(keyCount: 2, editing: editing)
            where ["Back", "Done", "Remove"].contains(spec.label) {
                XCTAssertNil(spec.shedOrder, "\(spec.label) must not shed")
            }
        }
    }
}
