//
//  UnhandledScrollGestureForwarder.swift
//  flutter_inappwebview
//

import AppKit
import WebKit

/// Hands unused horizontal gestures to the host only before WebKit sees more motion.
/// Delayed or coalesced reports keep the page, avoiding shared gesture ownership.
public final class UnhandledScrollGestureForwarder {
    /// Events kept while the owner is undecided.
    static let maxPendingEvents = 64
    /// A report this long after the gesture ended could interrupt the user's next gesture.
    static let lateReportAfterEnd: TimeInterval = 0.25

    private enum Owner {
        case undecided
        case page
        case host
    }

    private let forward: (NSEvent) -> Void
    private var tracking = false
    private var owner = Owner.page
    private var pending: [NSEvent] = []
    private var endedAt: TimeInterval?

    public init(forward: @escaping (NSEvent) -> Void) {
        self.forward = forward
    }

    /// Records the event before deciding whether WebKit may receive it.
    public func observe(_ event: NSEvent) {
        guard UnhandledScrollGestureForwarder.isTrackpadGestureEvent(event) else {
            return
        }
        let phase = event.phase
        if phase.contains(.mayBegin) || (phase.contains(.began) && !continuesMayBegin()) {
            tracking = true
            owner = .undecided
            pending = []
            endedAt = nil
        }
        guard tracking else {
            if phase.contains(.changed) || phase.contains(.ended) || phase.contains(.cancelled) {
                owner = .host
                forward(event)
            }
            return
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            tracking = false
            endedAt = ProcessInfo.processInfo.systemUptime
        }
        switch owner {
        case .host:
            forward(event)
        case .page:
            break
        case .undecided:
            if pending.count >= UnhandledScrollGestureForwarder.maxPendingEvents {
                giveToPage()
            } else {
                pending.append(event)
            }
        }
    }

    /// Handles WebKit's report that it did not use [event].
    public func didNotHandle(_ event: NSEvent) {
        if owner == .undecided, let endedAt = endedAt,
           ProcessInfo.processInfo.systemUptime - endedAt > UnhandledScrollGestureForwarder.lateReportAfterEnd {
            giveToPage()
        }
        guard owner == .undecided,
              let index = pending.firstIndex(where: { UnhandledScrollGestureForwarder.isSame($0, event) }),
              UnhandledScrollGestureForwarder.isMoving(pending[index]) else {
            return
        }
        let moving = pending[...index].filter(UnhandledScrollGestureForwarder.isMoving)
        let dx = moving.reduce(CGFloat(0)) { $0 + $1.scrollingDeltaX }
        let dy = moving.reduce(CGFloat(0)) { $0 + $1.scrollingDeltaY }
        guard moving.count == 1, pending.lastIndex(where: UnhandledScrollGestureForwarder.isMoving) == index,
              abs(dx) > abs(dy) else {
            giveToPage()
            return
        }
        owner = .host
        let events = pending
        pending = []
        events.forEach(forward)
    }

    // End/cancel still clears WebKit's scrolling latch after a host-owned gesture.
    public func shouldSendToWebKit(_ event: NSEvent) -> Bool {
        return owner != .host || (!event.phase.contains(.changed) && event.momentumPhase.isEmpty)
    }

    /// WebKit counts horizontal rubber-banding as consumed scrolling.
    /// Without the optional SPI, normal WebKit behavior remains unchanged.
    public static func stopHorizontalRubberBanding(_ webView: WKWebView) {
        let key = "rubberBandingEnabled"
        guard webView.responds(to: NSSelectorFromString("_setRubberBandingEnabled:")),
              let edges = webView.value(forKey: key) as? UInt else {
            return
        }
        let horizontal: UInt = (1 << CGRectEdge.minXEdge.rawValue) | (1 << CGRectEdge.maxXEdge.rawValue)
        webView.setValue(edges & ~horizontal, forKey: key)
    }

    /// Forgets the current gesture, e.g. when the web view is disposed.
    public func reset() {
        tracking = false
        giveToPage()
    }

    private func giveToPage() {
        owner = .page
        pending = []
    }

    /// A `began` that follows a lone `mayBegin` belongs to the same touch.
    private func continuesMayBegin() -> Bool {
        return tracking && owner == .undecided && pending.count == 1
            && pending[0].phase.contains(.mayBegin)
    }

    static func isTrackpadGestureEvent(_ event: NSEvent) -> Bool {
        return event.type == .scrollWheel && event.hasPreciseScrollingDeltas
            && !event.phase.isEmpty && event.momentumPhase.isEmpty
    }

    static func isMoving(_ event: NSEvent) -> Bool {
        return (event.phase.contains(.began) || event.phase.contains(.changed))
            && (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0)
    }

    /// WebKit reports the NSEvent it was given; a coalesced batch reports its last event.
    static func isSame(_ a: NSEvent, _ b: NSEvent) -> Bool {
        return a === b || (a.timestamp == b.timestamp && a.phase == b.phase
            && a.scrollingDeltaX == b.scrollingDeltaX && a.scrollingDeltaY == b.scrollingDeltaY)
    }
}
