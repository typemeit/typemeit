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

/// Reads which call a recording is, the Meet code from the tab's address or
/// the huddle's channel from a Slack window's title, so a rejoin of the same
/// call is joined and another call is not (docs/meetings.md 8.6, 9.2). No
/// new permission: the app already has Accessibility.
///
/// Names, speakers and captions are not read. `RosterRules` was written from
/// other projects' notes, not from Slack and Meet as they are: on four calls
/// on 24 and 25 September it found no one, and once took Meet's "Pinned for
/// yourself" for a person, which titled the meeting and named the far end.
/// Dev builds keep what the window exposes early in each call, so the rules
/// can be written from that before names come back.
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
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(Fixed.meetingCallKeyPollSeconds))
        timer.setEventHandler { @Sendable [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        if Updates.isDevBuild { startCapture() }
        DebugLog.write("Meeting call: reading the \(target.rawValue) window")
    }

    private func poll() {
        guard let ms = now(), let key = Roster.callKey(pid: pid, target: target) else { return }
        lock.lock()
        accumulator.add(RosterReading(call: key), atMs: ms)
        lastMs = ms
        readings += 1
        lock.unlock()
    }

    /// Stops polling, clears the activation attribute, and returns what was read.
    func finish() -> MeetingNames? {
        timer?.cancel()
        timer = nil
        queue.sync {
            captureTimer?.cancel()
            captureTimer = nil
            writeCapture()
        }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), target.activation as CFString, kCFBooleanFalse)
        lock.lock()
        defer { lock.unlock() }
        let names = accumulator.finish(atMs: lastMs)
        DebugLog.write("Meeting call: \(names?.call ?? "not read") after \(counted(readings, "reading"))")
        return names
    }

    /// Which call this is: the Meet code from the tab's address, or the
    /// channel from a Slack window's title.
    static func callKey(pid: pid_t, target: Target) -> String? {
        let app = AXUIElementCreateApplication(pid)
        for window in children(app, kAXWindowsAttribute) {
            switch target {
            case .slackHuddle:
                if let channel = string(window, kAXTitleAttribute).flatMap(RosterRules.Slack.channel(inTitle:)) { return channel }
            case .meet:
                for area in webAreas(under: window) {
                    if let address = url(of: area), address.host == "meet.google.com", let code = RosterRules.Meet.code(inPath: address.path) { return code }
                }
            }
        }
        return nil
    }

    // MARK: Capture (dev builds)

    /// How far into a call the capture starts, once people have joined, and
    /// how long it follows the window's changes after its full snapshot.
    private static let captureAfterSeconds = 20
    private static let captureSeconds = 30
    private var captureTimer: DispatchSourceTimer?
    private var captureLines: [String] = []
    private var captureStartMs: Int?
    private var previousLines: Set<String> = []

    /// Every poll interval from `captureAfterSeconds` in: the whole meeting
    /// window once, then the lines that appeared and went at each poll, which
    /// is where a speaking indicator shows. Written to
    /// `MeetingProbes.directory`; it holds whatever the window shows,
    /// messages included, and stays on this Mac.
    private func startCapture() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(Roster.captureAfterSeconds), repeating: .milliseconds(Fixed.meetingSpeakingPollMs))
        timer.setEventHandler { @Sendable [weak self] in self?.captureTick() }
        timer.resume()
        captureTimer = timer
    }

    private func captureTick() {
        guard let ms = now() else { return }
        let lines = Roster.windowLines(pid: pid, target: target)
        let current = Set(lines)
        if let start = captureStartMs {
            let gone = previousLines.subtracting(current).sorted(), came = current.subtracting(previousLines).sorted()
            if !gone.isEmpty || !came.isEmpty { captureLines += ["t=\(ms)"] + gone.map { "- " + $0 } + came.map { "+ " + $0 } }
            if ms - start >= Roster.captureSeconds * 1000 {
                captureTimer?.cancel()
                captureTimer = nil
                writeCapture()
            }
        } else {
            captureStartMs = ms
            captureLines = ["\(target.rawValue), meeting time \(ms) ms"] + lines
        }
        previousLines = current
    }

    private func writeCapture() {
        guard !captureLines.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let file = MeetingProbes.directory.appendingPathComponent("capture-\(target.rawValue)-\(stamp).txt")
        do {
            try FileManager.default.createDirectory(at: MeetingProbes.directory, withIntermediateDirectories: true)
            try captureLines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            DebugLog.write("Meeting capture: \(counted(captureLines.count, "line")) to \(file.lastPathComponent)")
        } catch {
            DebugLog.write("Meeting capture: \(error.localizedDescription)")
        }
        captureLines = []
    }

    /// Every window's title, and the elements of the meeting's part of the
    /// app one per line: for Meet, each web area on meet.google.com or in a
    /// window whose title says Meet, which is where a picture-in-picture call
    /// sits; for Slack, every window.
    static func windowLines(pid: pid_t, target: Target) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var lines: [String] = []
        for window in children(app, kAXWindowsAttribute) {
            let title = string(window, kAXTitleAttribute) ?? ""
            lines.append("window \(title)")
            var nodes: [AXNode] = []
            switch target {
            case .slackHuddle:
                walk(window, depth: 0, maxDepth: depthLimit, into: &nodes)
            case .meet:
                for area in webAreas(under: window) {
                    let address = url(of: area)
                    guard address?.host == "meet.google.com" || title.localizedCaseInsensitiveContains("meet") else { continue }
                    lines.append("area \(address?.absoluteString ?? "no address")")
                    walk(area, depth: 0, maxDepth: depthLimit, into: &nodes)
                }
            }
            lines += nodes.map(line)
        }
        return lines
    }

    private static func line(_ node: AXNode) -> String {
        let parts: [String?] = [
            node.role, node.subrole.map { "(\($0))" }, node.title.map { "title=\($0)" }, node.description.map { "desc=\($0)" },
            node.value.map { "value=\($0)" }, node.domIdentifier.map { "#\($0)" },
            node.domClasses.isEmpty ? nil : node.domClasses.map { "." + $0 }.joined(separator: " "), node.selected ? "selected" : nil,
        ]
        return String(repeating: " ", count: node.depth) + parts.compactMap { $0 }.joined(separator: " ")
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
