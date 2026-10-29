import AppKit

// The companion's window: borderless, never activates the app, and handles
// its own mouse events. The pill relies on isMovableByWindowBackground, which
// SwiftUI gestures can swallow; moving the window here, before SwiftUI sees
// the event, keeps dragging reliable.
final class CompanionPanel: NSPanel {

    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onDragMove: (() -> Void)?
    var onDragEnd: (() -> Void)?

    // A press that moves less than this is a click, so a shaky click never
    // nudges the character.
    static let dragThreshold: CGFloat = 4

    private var dragStart: NSPoint?
    private var originStart: NSPoint = .zero
    private var dragging = false

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Closing the panel runs NSApp.hide, which would take the companion
        // down with it.
        canHide = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            onContextMenu?(event)
        case .leftMouseDown where event.modifierFlags.contains(.control):
            onContextMenu?(event)
        case .leftMouseDown:
            dragStart = NSEvent.mouseLocation
            originStart = frame.origin
            dragging = false
        case .leftMouseDragged:
            guard let start = dragStart else { return }
            let p = NSEvent.mouseLocation
            if !dragging, hypot(p.x - start.x, p.y - start.y) > Self.dragThreshold { dragging = true }
            if dragging {
                setFrameOrigin(NSPoint(x: originStart.x + p.x - start.x, y: originStart.y + p.y - start.y))
                onDragMove?()
            }
        case .leftMouseUp:
            defer { dragStart = nil; dragging = false }
            guard dragStart != nil else { return }
            if dragging { onDragEnd?() } else { onClick?() }
        default:
            super.sendEvent(event)
        }
    }
}

// Where the companion sits, as the character's bottom-right corner, so a size
// change grows it up and to the left and it never jumps off its spot.
enum CompanionPlacement {

    // Pulls an anchor onto the nearest screen, so a spot saved over the Dock or
    // on a disconnected display is kept as close as possible instead of reset.
    // An anchor already inside a screen is left alone.
    static func clamp(_ p: CGPoint, size: CGSize, screens: [CGRect]) -> CGPoint {
        guard !screens.isEmpty else { return p }
        func distance(_ r: CGRect) -> CGFloat {
            hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
        }
        let frame = screens.min { distance($0) < distance($1) }!
        return CGPoint(x: min(max(p.x, frame.minX + size.width), frame.maxX),
                       y: min(max(p.y, frame.minY), frame.maxY - size.height))
    }

    static func defaultAnchor(visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.maxX - 28, y: visibleFrame.minY + 20)
    }

    static func origin(anchor: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: anchor.x - size.width, y: anchor.y)
    }

    // Where the panel opens beside the character: below it when the character
    // is in the top half of the screen, above it otherwise, and lined up with
    // the edge nearer the screen's middle so it grows into open space.
    static func panelFrame(character: CGRect, visible: CGRect, size: CGSize, gap: CGFloat = 4) -> CGRect {
        let below = character.midY > visible.midY
        let alignRight = character.midX >= visible.midX
        var x = alignRight ? character.maxX - size.width : character.minX
        x = max(visible.minX, min(x, visible.maxX - size.width))
        var y = below ? character.minY - gap - size.height : character.maxY + gap
        y = max(visible.minY, min(y, visible.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
