import AppKit
import ApplicationServices
import Foundation

/// One element of a meeting window, flattened: what the rules in
/// `RosterRules` look at. Built from the accessibility tree, which for
/// Chromium and Electron mirrors the page's roles, labels and text.
struct AXNode: Equatable, Sendable {
    var depth: Int
    var role: String
    var subrole: String?
    var title: String?
    var description: String?
    var value: String?
    var domIdentifier: String?
    var domClasses: [String] = []
    var selected = false

    /// Every text the element carries, in the order a reader would say it.
    var texts: [String] { [title, description, value].compactMap { $0 }.filter { !$0.isEmpty } }
}

/// Reads who is in a Slack huddle or a Meet call, who is speaking and
/// what the captions say, from the app's window while a meeting records
/// (docs/meetings.md 8.6, 9.2). No new permission: the app already has
/// Accessibility. Polls on its own queue; every reading goes through the
/// target's pure rules into a `RosterAccumulator`.
final class Roster: @unchecked Sendable {
    enum Target: String, Sendable {
        case meet, slackHuddle

        /// The meeting app's target, or nil when names cannot be read from it.
        static func of(_ owner: ProcessOwner.Owner) -> Target? {
            switch owner.bundleID {
            case "com.tinyspeck.slackmacgap": .slackHuddle
            case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac": .meet
            default: nil
            }
        }

        /// Electron honours `AXManualAccessibility`; Chromium, `AXEnhancedUserInterface`.
        var activation: String { self == .slackHuddle ? "AXManualAccessibility" : "AXEnhancedUserInterface" }
    }

    let target: Target
    private let pid: pid_t
    private let now: @Sendable () -> Int?
    private let queue = DispatchQueue(label: "it.typeme.typemeit.meeting-roster", qos: .utility)
    private let lock = NSLock()
    private var accumulator = RosterAccumulator(minimumSpanMs: Fixed.meetingSpeakingPollMs)
    private var timer: DispatchSourceTimer?
    private var lastMs = 0
    private var readings = 0

    /// `now` gives meeting time in ms, nil until the recording's clock starts.
    init?(owner: ProcessOwner.Owner, now: @escaping @Sendable () -> Int?) {
        guard let target = Target.of(owner),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: owner.bundleID).first(where: { $0.activationPolicy == .regular }) else { return nil }
        self.target = target
        self.pid = app.processIdentifier
        self.now = now
    }

    func start() {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(root, target.activation as CFString, kCFBooleanTrue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Fixed.meetingSpeakingPollMs), repeating: .milliseconds(Fixed.meetingSpeakingPollMs))
        timer.setEventHandler { @Sendable [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        DebugLog.write("Meeting names: reading the \(target.rawValue) window")
    }

    private func poll() {
        guard let ms = now() else { return }
        let (nodes, code) = Roster.meetingNodes(pid: pid, target: target)
        guard !nodes.isEmpty else { return }
        var reading = RosterRules.read(nodes, target: target)
        reading.call = code ?? reading.channel
        lock.lock()
        accumulator.add(reading, atMs: ms)
        lastMs = ms
        readings += 1
        lock.unlock()
    }

    /// Stops polling, clears the activation attribute, and returns what was read.
    func finish() -> MeetingNames? {
        timer?.cancel()
        timer = nil
        queue.sync {}
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), target.activation as CFString, kCFBooleanFalse)
        lock.lock()
        defer { lock.unlock() }
        let names = accumulator.finish(atMs: lastMs)
        DebugLog.write("Meeting names: \(readings) readings, \(counted(names?.roster.count ?? 0, "name")), \(counted(names?.spans.count ?? 0, "turn")), \(counted(names?.captions?.count ?? 0, "caption line")), source \(names?.source.rawValue ?? "none")")
        return names
    }

    // MARK: The tree

    /// The meeting's part of the app: for Meet, the web area of the tab on
    /// meet.google.com; for Slack, every window, since a huddle can sit in
    /// the main window as well as its own, walked no deeper than its tiles.
    /// Also the Meet code from the tab's address, for Meet.
    static func meetingNodes(pid: pid_t, target: Target) -> (nodes: [AXNode], meetCode: String?) {
        let app = AXUIElementCreateApplication(pid)
        var nodes: [AXNode] = []
        var code: String?
        for window in children(app, kAXWindowsAttribute) {
            switch target {
            case .slackHuddle:
                walk(window, depth: 0, maxDepth: slackDepthLimit, into: &nodes)
            case .meet:
                for area in webAreas(under: window) {
                    guard let address = url(of: area), address.host == "meet.google.com" else { continue }
                    code = code ?? RosterRules.Meet.code(inPath: address.path)
                    walk(area, depth: 0, maxDepth: depthLimit, into: &nodes)
                }
            }
        }
        return (nodes, code)
    }

    private static let nodeLimit = 20_000
    private static let depthLimit = 80
    /// Pipit (MIT) reads huddle tiles from 24 levels down; the rest of the
    /// main window is deeper and not wanted.
    private static let slackDepthLimit = 32

    /// Read in one round trip per element: a Meet page is a few thousand
    /// elements, and one call per attribute would take longer than a poll.
    private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                     kAXValueAttribute, "AXDOMIdentifier", "AXDOMClassList", kAXSelectedAttribute, kAXChildrenAttribute]

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, into nodes: inout [AXNode]) {
        guard depth < maxDepth, nodes.count < nodeLimit else { return }
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let v = values as? [AnyObject], v.count == attributes.count else { return }
        func text(_ i: Int) -> String? { (v[i] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var node = AXNode(depth: depth, role: text(0) ?? "")
        node.subrole = text(1)
        node.title = text(2)
        node.description = text(3)
        node.value = text(4)
        node.domIdentifier = text(5)
        node.domClasses = v[6] as? [String] ?? []
        node.selected = (v[7] as? Bool) ?? false
        nodes.append(node)
        for child in v[8] as? [AXUIElement] ?? [] { walk(child, depth: depth + 1, maxDepth: maxDepth, into: &nodes) }
    }

    private static func webAreas(under element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < depthLimit else { return [] }
        if string(element, kAXRoleAttribute) == "AXWebArea" { return [element] }
        return children(element, kAXChildrenAttribute).flatMap { webAreas(under: $0, depth: depth + 1) }
    }

    private static func url(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }

    private static func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
