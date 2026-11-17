import AppKit
import WebKit

// Stands in for the production platform-view container: the glue forwards only
// when the web view is hosted by it.
final class FlutterWebViewController: NSView {}

final class Recorder: NSView {
    var received: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { received.append(event) }
}

class ProbeWebView: WKWebView, WKUIDelegate, WKNavigationDelegate {
    var loaded = false

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        uiDelegate = self
        navigationDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

__GLUE__
}

final class TracingWebView: ProbeWebView {
    var reports: [NSEvent] = []

    @objc(_webView:didNotHandleWheelEvent:)
    override func webViewDidNotHandleWheelEvent(_ webView: WKWebView, event: NSEvent) {
        reports.append(event)
        super.webViewDidNotHandleWheelEvent(webView, event: event)
    }
}

enum ScrollPhase: Int64 {
    case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
}

var failures: [String] = []
var timestamp: CGEventTimestamp = 1_000_000_000

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("PASS \(name)")
    } else {
        let message = "FAIL \(name) \(detail())"
        print(message)
        failures.append(message)
    }
}

/// [screenPoint] uses Cocoa screen coordinates (origin bottom-left).
func makeEvent(dx: Double = 0, dy: Double = 0, phase: ScrollPhase, momentum: Int64 = 0,
               continuous: Bool = true, at screenPoint: NSPoint = .zero) -> NSEvent {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                     wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)!
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    if continuous {
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
    }
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    cg.location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
    timestamp += 16_000_000
    cg.timestamp = timestamp
    return NSEvent(cgEvent: cg)!
}

/// A two-finger gesture: optional mayBegin, began, [steps] changes, ended, optional momentum.
func gesture(dx: Double, dy: Double, steps: Int = 8, mayBegin: Bool = false,
             momentum: Bool = false, at point: NSPoint = .zero) -> [NSEvent] {
    var events: [NSEvent] = []
    if mayBegin { events.append(makeEvent(phase: .mayBegin, at: point)) }
    events.append(makeEvent(phase: .began, at: point))
    for _ in 0..<steps {
        events.append(makeEvent(dx: dx / Double(steps), dy: dy / Double(steps), phase: .changed, at: point))
    }
    events.append(makeEvent(phase: .ended, at: point))
    if momentum {
        events.append(makeEvent(dx: dx / 4, phase: .none, momentum: 1, at: point))
        events.append(makeEvent(dx: dx / 8, phase: .none, momentum: 2, at: point))
        events.append(makeEvent(phase: .none, momentum: 3, at: point))
    }
    return events
}

func phases(_ events: [NSEvent]) -> String {
    return events.map { "\($0.phase.rawValue)/\($0.momentumPhase.rawValue)" }.joined(separator: ",")
}

func sameEvents(_ a: [NSEvent], _ b: [NSEvent]) -> Bool {
    return a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
}

func isMoving(_ event: NSEvent) -> Bool { UnhandledScrollGestureForwarder.isMoving(event) }

// Ownership rules, driven directly without WebKit.
func runLogicCases() {
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -80, dy: 4)
        events.forEach(f.observe)
        f.didNotHandle(events[1])
        check(out.isEmpty, "logic: a report with later motion already in WebKit keeps the page", phases(out))
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: 80, dy: 0)
        for (i, e) in events.enumerated() {
            f.observe(e)
            if i == 1 { f.didNotHandle(events[1]) }
        }
        check(sameEvents(out, events), "logic: events after the decision are forwarded live", phases(out))
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: 80, dy: 0)
        events.forEach(f.observe)
        f.didNotHandle(events[5])
        f.didNotHandle(events[1])
        check(out.isEmpty, "logic: a report after earlier page-owned motion keeps the page", phases(out))
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: 20, dy: -60)
        events.forEach(f.observe)
        f.didNotHandle(events[1])
        check(out.isEmpty, "logic: a mostly vertical gesture is not forwarded")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -60, dy: 0, mayBegin: true)
        events.prefix(3).forEach(f.observe)
        f.didNotHandle(events[0])
        f.didNotHandle(events[1])
        check(out.isEmpty, "logic: reports for the start events alone do not decide")
        f.didNotHandle(events[2])
        events.dropFirst(3).forEach(f.observe)
        check(sameEvents(out, events), "logic: mayBegin and began belong to one gesture", phases(out))
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -80, dy: 0, momentum: true)
        f.observe(events[0])
        f.observe(events[1])
        f.didNotHandle(events[1])
        let allowed = events.dropFirst(2).filter { event in
            f.observe(event)
            return f.shouldSendToWebKit(event)
        }
        check(allowed.count == 1 && allowed[0].phase.contains(.ended),
              "logic: host owns subsequent motion and momentum, WebKit still receives the end", phases(allowed))
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -80, dy: 0)
        events.prefix(3).forEach(f.observe)
        f.didNotHandle(events[2])
        check(out.isEmpty, "logic: a used first motion cannot transfer ownership on the second motion")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let began = makeEvent(dx: 12, phase: .began)
        let changed = makeEvent(dx: 12, phase: .changed)
        f.observe(began)
        f.observe(changed)
        f.didNotHandle(changed)
        check(out.isEmpty, "logic: movement consumed during began keeps the page")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let began = makeEvent(dx: 12, phase: .began)
        f.observe(began)
        f.didNotHandle(began)
        let cancelled = makeEvent(phase: .cancelled)
        f.observe(cancelled)
        check(sameEvents(out, [began, cancelled]) && f.shouldSendToWebKit(cancelled),
              "logic: unused motion during began can transfer, cancellation still reaches WebKit")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let first = gesture(dx: -60, dy: 0)
        first.forEach(f.observe)
        let second = gesture(dx: -60, dy: 0)
        second.forEach(f.observe)
        f.didNotHandle(first[1])
        check(out.isEmpty, "logic: a late report for a previous gesture is ignored")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -60, dy: 0, momentum: true)
        for (i, event) in events.enumerated() {
            f.observe(event)
            if i == 1 { f.didNotHandle(event) }
        }
        check(out.count == events.count - 3 && out.allSatisfy { $0.momentumPhase.isEmpty },
              "logic: momentum events are never forwarded", phases(out))
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let wheel = makeEvent(dx: 40, phase: .none, continuous: false)
        f.observe(wheel)
        f.didNotHandle(wheel)
        check(out.isEmpty, "logic: mouse wheel events are ignored")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = [makeEvent(phase: .mayBegin), makeEvent(phase: .cancelled)]
        events.forEach(f.observe)
        f.didNotHandle(events[0])
        f.didNotHandle(events[1])
        check(out.isEmpty, "logic: a touch that never moves is not forwarded")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -60, dy: 0, steps: 80)
        events.forEach(f.observe)
        f.didNotHandle(events[2])
        check(out.isEmpty, "logic: an undecided gesture beyond the pending limit stays with the page")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -60, dy: 0)
        events.prefix(4).forEach(f.observe)
        f.reset()
        f.didNotHandle(events[2])
        check(out.isEmpty, "logic: reset drops the gesture in progress")
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -60, dy: 0)
        events.dropFirst(3).forEach(f.observe)
        check(sameEvents(out, Array(events.dropFirst(3))),
              "logic: a gesture that began outside the web view goes on to the host", phases(out))
    }
    do {
        var out: [NSEvent] = []
        let f = UnhandledScrollGestureForwarder { out.append($0) }
        let events = gesture(dx: -60, dy: 0)
        events.forEach(f.observe)
        Thread.sleep(forTimeInterval: UnhandledScrollGestureForwarder.lateReportAfterEnd + 0.1)
        f.didNotHandle(events[1])
        check(out.isEmpty, "logic: a report long after the gesture ended is dropped")
    }
}

@MainActor
final class ProbeApplication: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let recorder = Recorder(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let host = FlutterWebViewController(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    var webView: TracingWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            runLogicCases()
            await runWebKitCases()
            window.close()
            print(failures.isEmpty ? "ALL PASSED" : "\(failures.count) FAILED")
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func load(_ html: String) async {
        webView.loaded = false
        webView.loadHTMLString("<meta charset=utf-8>" + html, baseURL: nil)
        for _ in 0..<200 where !webView.loaded { await sleep(0.05) }
        check(webView.loaded, "page loaded")
        await sleep(0.5) // Let the scrolling tree commit before the first event.
    }

    func js(_ script: String) async -> Any? {
        return try? await webView.evaluateJavaScript(script)
    }

    var center: NSPoint {
        let inWindow = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        return window.convertPoint(toScreen: inWindow)
    }

    /// Sends [events] at the real input cadence and returns what reached the host.
    func send(_ events: [NSEvent]) async -> [NSEvent] {
        recorder.received = []
        webView.reports = []
        for event in events {
            webView.scrollWheel(with: event)
            await sleep(0.016)
        }
        await sleep(0.8)
        print("  WebKit left unused: \(phases(webView.reports))")
        return recorder.received
    }

    func runWebKitCases() async {
        // At the screen origin, window and screen coordinates agree, so the location of
        // an NSEvent built from a CGEvent is right whichever space WebKit reads.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(.zero)
        window.contentView = recorder
        recorder.addSubview(host)
        webView = TracingWebView(frame: host.bounds, configuration: WKWebViewConfiguration())
        host.addSubview(webView)
        let edgesBefore = webView.value(forKey: "rubberBandingEnabled") as? UInt
        UnhandledScrollGestureForwarder.stopHorizontalRubberBanding(webView)
        let edgesAfter = webView.value(forKey: "rubberBandingEnabled") as? UInt
        check(edgesBefore == 15 && edgesAfter == 10, "webkit: only the left and right edges stop rubber-banding",
              "before \(String(describing: edgesBefore)) after \(String(describing: edgesAfter))")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await sleep(0.3)
        print("window frame \(window.frame), web view center on screen \(center)")

        let plain = "<p>plain plugin page</p>"
        await load(plain)
        var events = gesture(dx: -90, dy: 3, at: center)
        var out = await send(events)
        check(sameEvents(out, events), "webkit: horizontal swipe over a page that cannot use it reaches the host",
              "sent \(phases(events)) got \(phases(out))")

        events = gesture(dx: 90, dy: 0, mayBegin: true, momentum: true, at: center)
        out = await send(events)
        check(sameEvents(out, Array(events.dropLast(3))),
              "webkit: the opposite swipe arrives whole, without momentum",
              "got \(phases(out))")

        out = await send(gesture(dx: 0, dy: -90, at: center))
        check(out.isEmpty, "webkit: a vertical swipe stays with the page", phases(out))

        out = await send([makeEvent(dx: 3, phase: .none, continuous: false, at: center)])
        check(out.isEmpty, "webkit: a mouse wheel stays with the page", phases(out))

        await load("<style>html,body{margin:0;height:100%;overflow:hidden}</style><div style=height:100%>fixed</div>")
        events = gesture(dx: -90, dy: 0, at: center)
        out = await send(events)
        check(sameEvents(out, events), "webkit: overflow hidden page forwards the swipe", phases(out))

        await load("<script>window.n=0;addEventListener('wheel',()=>n++)</script><p>listener</p>")
        events = gesture(dx: -90, dy: 0, at: center)
        out = await send(events)
        let listened = await js("n") as? Int ?? 0
        check(listened > 0 && sameEvents(out, events),
              "webkit: a listener that does not prevent default still lets the swipe through",
              "listener calls \(listened), got \(phases(out))")

        await load("<div style=\"height:5000px\">tall</div>")
        var tall = [makeEvent(phase: .began, at: center)]
        tall += (0..<2).map { _ in makeEvent(dx: -4, dy: 3, phase: .changed, at: center) }
        tall += (0..<7).map { _ in makeEvent(dx: -12, phase: .changed, at: center) }
        tall.append(makeEvent(phase: .ended, at: center))
        out = await send(tall)
        let tallY = await js("scrollY") as? Double ?? -1
        check(sameEvents(out, tall), "webkit: a mostly horizontal swipe over a vertically scrolling page reaches the host",
              "scrollY \(tallY), got \(phases(out))")

        await load(plain + "<script>history.pushState({},'','#a');history.pushState({},'','#b')</script>")
        webView.allowsBackForwardNavigationGestures = true
        out = await send(gesture(dx: 90, dy: 0, at: center))
        let hash = await js("location.hash") as? String ?? "?"
        print("  with back/forward gestures and history: hash \(hash), forwarded \(out.count)")
        webView.allowsBackForwardNavigationGestures = false
        await load(plain + "<script>history.pushState({},'','#a');history.pushState({},'','#b')</script>")
        events = gesture(dx: 90, dy: 0, at: center)
        out = await send(events)
        check(sameEvents(out, events), "webkit: with back/forward gestures off, a page with history forwards the swipe",
              phases(out))

        let scroller = "<div id=s style=\"position:absolute;inset:0;overflow-x:auto\"><div style=\"width:4000px;height:10px\"></div></div>"
        await load(scroller + "<script>s.scrollLeft=1000</script>")
        out = await send(gesture(dx: -90, dy: 0, at: center))
        let scrolled = await js("s.scrollLeft") as? Double ?? 1000
        check(out.isEmpty && scrolled != 1000, "webkit: a horizontal scroller keeps the swipe",
              "scrollLeft \(scrolled), got \(phases(out))")

        await load("<div style=\"width:4000px;height:10px\"></div><script>scrollTo(1000,0)</script>")
        out = await send(gesture(dx: -90, dy: 0, at: center))
        let rootX = await js("scrollX") as? Double ?? 1000
        check(out.isEmpty && rootX != 1000, "webkit: a horizontally scrolling page keeps the swipe",
              "scrollX \(rootX), got \(phases(out))")

        await load("<canvas id=c style=\"position:absolute;inset:0;width:100%;height:100%\"></canvas><script>window.n=0;c.addEventListener('wheel',e=>{n++;e.preventDefault()},{passive:false})</script>")
        out = await send(gesture(dx: -90, dy: 0, at: center))
        let prevented = await js("n") as? Int ?? 0
        check(out.isEmpty && prevented > 0, "webkit: a canvas that prevents default keeps the swipe",
              "prevented \(prevented), got \(phases(out))")

        let frameDoc = "<body style=margin:0><div id=s style='position:absolute;inset:0;overflow-x:auto'><div style='width:4000px;height:10px'></div></div><script>s.scrollLeft=1000</script></body>"
        await load("<iframe srcdoc=\"\(frameDoc)\" style=\"position:absolute;inset:0;border:0;width:100%;height:100%\"></iframe>")
        await sleep(0.3)
        out = await send(gesture(dx: -90, dy: 0, at: center))
        check(out.isEmpty, "webkit: a scroller inside an iframe keeps the swipe", phases(out))

        await load("<div id=h style=\"position:absolute;inset:0\"></div><script>const r=h.attachShadow({mode:'closed'});r.innerHTML='<div id=s style=\"width:100%;height:100%;overflow-x:auto\"><div style=\"width:4000px;height:10px\"></div></div>';window.sc=r.getElementById('s');sc.scrollLeft=1000</script>")
        out = await send(gesture(dx: -90, dy: 0, at: center))
        let shadowX = await js("sc.scrollLeft") as? Double ?? 1000
        check(out.isEmpty && shadowX != 1000, "webkit: a scroller in a closed shadow root keeps the swipe",
              "scrollLeft \(shadowX), got \(phases(out))")

        await load(scroller)
        var reverse = [makeEvent(phase: .began, at: center)]
        reverse += (0..<4).map { _ in makeEvent(dx: 12, phase: .changed, at: center) }
        reverse += (0..<16).map { _ in makeEvent(dx: -12, phase: .changed, at: center) }
        reverse.append(makeEvent(phase: .ended, at: center))
        reverse += [makeEvent(dx: -36, phase: .none, momentum: 1, at: center),
                    makeEvent(dx: -18, phase: .none, momentum: 2, at: center),
                    makeEvent(phase: .none, momentum: 3, at: center)]
        out = await send(reverse)
        let reverseX = await js("s.scrollLeft") as? Double ?? -1
        check(out.isEmpty || reverseX == 0, "webkit: host-owned swipe cannot also scroll page after reversal",
              "scrollLeft \(reverseX), forwarded \(out.count)")

        out = await send(gesture(dx: -120, dy: 0, at: center))
        let nextX = await js("s.scrollLeft") as? Double ?? 0
        check(out.isEmpty && nextX > 0, "webkit: the next page-owned gesture scrolls after the host gesture ended",
              "scrollLeft \(nextX), forwarded \(out.count)")

        await load(scroller + "<script>s.scrollLeft=5</script>")
        out = await send(gesture(dx: 120, dy: 0, at: center))
        let edgeX = await js("s.scrollLeft") as? Double ?? -1
        check(out.isEmpty && edgeX == 0, "webkit: a scroller reaching its edge keeps the entire gesture",
              "scrollLeft \(edgeX), forwarded \(out.count)")

        for terminal in [ScrollPhase.ended, .cancelled] {
            await load(scroller)
            var terminalMotion = [makeEvent(phase: .began, at: center),
                                  makeEvent(dx: 12, phase: .changed, at: center)]
            terminalMotion.append(makeEvent(dx: -60, phase: terminal, at: center))
            out = await send(terminalMotion)
            let terminalX = await js("s.scrollLeft") as? Double ?? -1
            check(sameEvents(out, terminalMotion) && terminalX == 0,
                  "webkit: host-owned nonzero terminal motion cannot scroll the page (\(terminal))",
                  "scrollLeft \(terminalX), forwarded \(out.count)")
        }

        await load(scroller + "<script>s.scrollLeft=5</script>")
        var movingBegan = [makeEvent(dx: 12, phase: .began, at: center)]
        movingBegan += (0..<8).map { _ in makeEvent(dx: 12, phase: .changed, at: center) }
        movingBegan.append(makeEvent(phase: .ended, at: center))
        out = await send(movingBegan)
        check(out.isEmpty, "webkit: scrolling during began cannot later transfer to the host", phases(out))

        await load(scroller)
        let cancel = [makeEvent(phase: .began, at: center),
                      makeEvent(dx: 12, phase: .changed, at: center),
                      makeEvent(phase: .cancelled, at: center)]
        out = await send(cancel)
        check(sameEvents(out, cancel), "webkit: a host-owned gesture delivers cancellation")
        out = await send(gesture(dx: -120, dy: 0, at: center))
        let cancelledX = await js("s.scrollLeft") as? Double ?? 0
        check(out.isEmpty && cancelledX > 0, "webkit: page scrolling works after host cancellation")

        await load(scroller)
        var burst = [makeEvent(phase: .began, at: center),
                     makeEvent(dx: 12, phase: .changed, at: center)]
        burst += (0..<16).map { _ in makeEvent(dx: -12, phase: .changed, at: center) }
        burst.append(makeEvent(phase: .ended, at: center))
        recorder.received = []
        burst.forEach { webView.scrollWheel(with: $0) }
        await sleep(0.8)
        let burstX = await js("s.scrollLeft") as? Double ?? -1
        check(recorder.received.isEmpty && burstX > 0,
              "webkit: a delayed unused report cannot claim a reversal already sent to WebKit",
              "scrollLeft \(burstX), forwarded \(recorder.received.count)")

        await load("<p id=t>טקסט נבחר בתוסף</p><script>const r=document.createRange();r.selectNodeContents(t);getSelection().addRange(r)</script>")
        events = gesture(dx: -90, dy: 0, at: center)
        out = await send(events)
        let selected = await js("getSelection().toString()") as? String ?? ""
        check(sameEvents(out, events) && selected == "טקסט נבחר בתוסף",
              "webkit: forwarding an unused swipe preserves the page selection", selected)

        await load("<canvas id=c style=\"position:absolute;inset:0;width:100%;height:100%\"></canvas><script>window.n=0;window.consumed=0;c.addEventListener('wheel',e=>{n++;if(n>3){consumed+=e.deltaX;e.preventDefault()}},{passive:false})</script>")
        out = await send(gesture(dx: -180, dy: 0, steps: 12, at: center))
        let consumed = await js("consumed") as? Double ?? 0
        check(out.isEmpty || consumed == 0, "webkit: host-owned swipe cannot also be consumed by custom page",
              "consumed \(consumed), forwarded \(out.count)")

        await load(plain)
        webView.removeFromSuperview()
        recorder.addSubview(webView)
        out = await send(gesture(dx: -90, dy: 0, at: center))
        check(out.isEmpty, "webkit: a web view outside a Flutter host forwards nothing", phases(out))
    }
}

@main
struct UnhandledScrollGestureProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ProbeApplication()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(2)
    }
}
