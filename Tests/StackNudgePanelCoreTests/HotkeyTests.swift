import Carbon.HIToolbox
import XCTest

@testable import StackNudgePanelCore

final class HotkeyTests: XCTestCase {

    // MARK: - parse

    func test_parse_singleModifierAndKey() throws {
        let parsed = try XCTUnwrap(Hotkey.parse("cmd+n"))
        XCTAssertEqual(parsed.modifiers, UInt32(cmdKey))
        XCTAssertEqual(parsed.keyCode, 45)
    }

    func test_parse_isCaseInsensitive() {
        let lower = Hotkey.parse("cmd+shift+n")
        let upper = Hotkey.parse("CMD+SHIFT+N")
        let mixed = Hotkey.parse("Cmd+Shift+N")
        XCTAssertNotNil(lower)
        XCTAssertEqual(lower?.modifiers, upper?.modifiers)
        XCTAssertEqual(lower?.keyCode,   upper?.keyCode)
        XCTAssertEqual(lower?.modifiers, mixed?.modifiers)
        XCTAssertEqual(lower?.keyCode,   mixed?.keyCode)
    }

    func test_parse_acceptsAllModifierAliases() throws {
        // alt = opt, command = cmd, control = ctrl, option = opt
        let opt    = try XCTUnwrap(Hotkey.parse("opt+a"))
        let alt    = try XCTUnwrap(Hotkey.parse("alt+a"))
        let option = try XCTUnwrap(Hotkey.parse("option+a"))
        XCTAssertEqual(opt.modifiers, alt.modifiers)
        XCTAssertEqual(opt.modifiers, option.modifiers)

        let cmd     = try XCTUnwrap(Hotkey.parse("cmd+a"))
        let command = try XCTUnwrap(Hotkey.parse("command+a"))
        XCTAssertEqual(cmd.modifiers, command.modifiers)

        let ctrl    = try XCTUnwrap(Hotkey.parse("ctrl+a"))
        let control = try XCTUnwrap(Hotkey.parse("control+a"))
        XCTAssertEqual(ctrl.modifiers, control.modifiers)
    }

    func test_parse_combinesMultipleModifiers() throws {
        let parsed = try XCTUnwrap(Hotkey.parse("cmd+shift+opt+ctrl+space"))
        let expected = UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey)
        XCTAssertEqual(parsed.modifiers, expected)
        XCTAssertEqual(parsed.keyCode, 49) // space
    }

    func test_parse_supportsNamedKeys() throws {
        XCTAssertEqual(try XCTUnwrap(Hotkey.parse("cmd+space")).keyCode,  49)
        XCTAssertEqual(try XCTUnwrap(Hotkey.parse("cmd+return")).keyCode, 36)
        XCTAssertEqual(try XCTUnwrap(Hotkey.parse("cmd+tab")).keyCode,    48)
        XCTAssertEqual(try XCTUnwrap(Hotkey.parse("cmd+escape")).keyCode, 53)
    }

    func test_parse_supportsDigitKeys() throws {
        XCTAssertEqual(try XCTUnwrap(Hotkey.parse("cmd+1")).keyCode, 18)
        XCTAssertEqual(try XCTUnwrap(Hotkey.parse("cmd+9")).keyCode, 25)
        XCTAssertEqual(try XCTUnwrap(Hotkey.parse("cmd+0")).keyCode, 29)
    }

    func test_parse_returnsNilOnEmpty() {
        XCTAssertNil(Hotkey.parse(""))
    }

    func test_parse_returnsNilOnUnknownKey() {
        XCTAssertNil(Hotkey.parse("cmd+not-a-key"))
    }

    func test_parse_returnsNilOnModifiersWithoutKey() {
        // Only modifiers were named; no key resolved.
        XCTAssertNil(Hotkey.parse("cmd+shift"))
    }

    // MARK: - encode

    func test_encode_singleModifier() {
        // 0x100000 = NSEvent.ModifierFlags.command.rawValue
        let spec = Hotkey.encode(eventModifiers: 0x100000, keyCode: 45)
        XCTAssertEqual(spec, "cmd+n")
    }

    func test_encode_emitsModifiersInDocumentedOrder() {
        // The implementation always emits in cmd, ctrl, opt, shift order so
        // the output is deterministic regardless of the input bit pattern.
        let all: UInt = 0x100000 | 0x040000 | 0x080000 | 0x020000
        let spec = Hotkey.encode(eventModifiers: all, keyCode: 45)
        XCTAssertEqual(spec, "cmd+ctrl+opt+shift+n")
    }

    func test_encode_returnsNilForUnknownKeyCode() {
        XCTAssertNil(Hotkey.encode(eventModifiers: 0x100000, keyCode: 999))
    }

    // MARK: - round-trip

    func test_parse_then_encode_roundTrip() throws {
        // For specs in canonical (cmd, ctrl, opt, shift, key) order, parse +
        // encode should be lossless.
        let specs = [
            "cmd+n",
            "cmd+shift+n",
            "cmd+opt+space",
            "cmd+ctrl+opt+shift+n",
            "shift+a",
        ]
        for spec in specs {
            let parsed = try XCTUnwrap(Hotkey.parse(spec), "parse failed: \(spec)")
            // Re-encode using NSEvent flag bits (the wire format encode expects).
            var ns: UInt = 0
            if parsed.modifiers & UInt32(cmdKey)     != 0 { ns |= 0x100000 }
            if parsed.modifiers & UInt32(shiftKey)   != 0 { ns |= 0x020000 }
            if parsed.modifiers & UInt32(optionKey)  != 0 { ns |= 0x080000 }
            if parsed.modifiers & UInt32(controlKey) != 0 { ns |= 0x040000 }
            let encoded = Hotkey.encode(eventModifiers: ns, keyCode: UInt16(parsed.keyCode))
            XCTAssertEqual(encoded, spec, "round-trip diverged for \(spec)")
        }
    }
}
