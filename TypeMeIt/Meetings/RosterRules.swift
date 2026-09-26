import Foundation

/// Which elements of a meeting window are the participants and which say
/// who is speaking, per app (docs/meetings.md 8.6, 9.2). Pure over the
/// flattened tree. Each rule names what it anchors on and where that was
/// seen working; a rule that stops matching yields nothing rather than a
/// wrong name, and alignment then leaves numbers.
enum RosterRules {
    static func read(_ nodes: [AXNode], target: Roster.Target) -> RosterReading {
        switch target {
        case .meet: meet(nodes)
        case .slackHuddle: slack(nodes)
        }
    }

    // MARK: Slack huddle

    /// Slack names its DOM after what things mean and Electron mirrors the
    /// DOM into the tree once `AXManualAccessibility` is set. Observed by
    /// Neeeser/Pipit (MIT), `SlackHuddleTile.swift`, 14 September 2026:
    /// a tile's `AXDOMIdentifier` is `huddle-grid-gridcell-<session>_<user
    /// id>` (`-self_` for the user's own); its name is in a description
    /// reading `View <Name>'s profile`; the speaking tile carries
    /// `p-huddle_peer_tile__overlay--active_speaker`, one tile at a time,
    /// released about 1.5 s after the voice stops. English UI only.
    enum Slack {
        static let tilePrefix = "huddle-grid-gridcell"
        static let tileDescriptionSuffix = "a11y_huddle_peer_tile_description"
        static let selfMarker = "-self_"
        static let speakingClass = "p-huddle_peer_tile__overlay--active_speaker"
        static let profilePrefix = "View "
        static let profileSuffix = "'s profile"

        /// The huddle's channel, the first `#` word of a window's title.
        static func channel(inTitle title: String) -> String? {
            title.split(separator: " ").first { $0.hasPrefix("#") }.map(String.init)
        }

        static func name(fromProfile text: String) -> String? {
            guard text.hasPrefix(profilePrefix), text.hasSuffix(profileSuffix) else { return nil }
            let name = String(text.dropFirst(profilePrefix.count).dropLast(profileSuffix.count))
            return name.isEmpty ? nil : name
        }
    }

    static func slack(_ nodes: [AXNode]) -> RosterReading {
        var reading = RosterReading()
        for node in nodes where node.role == "AXWindow" {
            if let channel = node.title.flatMap(Slack.channel(inTitle:)) { reading.channel = channel }
        }
        for i in tileRoots(nodes, target: .slackHuddle) {
            let tile = nodes[i..<subtreeEnd(of: i, in: nodes)]
            guard nodes[i].domIdentifier?.contains(Slack.selfMarker) == false,
                  let name = tile.lazy.flatMap(\.texts).compactMap(Slack.name(fromProfile:)).first else { continue }
            if !reading.roster.contains(name) { reading.roster.append(name) }
            if tile.contains(where: { $0.domClasses.contains(Slack.speakingClass) }) { reading.speaking.insert(name) }
        }
        return reading
    }

    // MARK: Meet

    /// Meet's class names are generated and change with its deploys; these
    /// two are the ones a real call showed. On the 25 September capture the
    /// user's tile was an `AXGroup` with class `dkjMxf` holding their name
    /// as an `AXStaticText`, and 73 s in, as they spoke, the tile gained
    /// `kssMZb`. murabcd/graneri (`ChromeMeetingSpeakerCLI.swift`) and
    /// salesforce-misc/thread (`SpeakerVisionMonitor.swift`, Apache-2.0)
    /// key on the same two. When Meet renames them nothing matches, the
    /// meeting is named from its voices alone, and the dev menu's Capture
    /// Meet Window shows what to match instead.
    enum Meet {
        static let tileClass = "dkjMxf"
        static let speakingClass = "kssMZb"
        /// What some layouts show on the user's own tile in place of a name.
        static let selfLabel = "You"
        /// A name is a few words; anything longer on a tile is something else.
        static let nameMaxWords = 5

        /// The meeting code from a Meet address's path, `/abc-defg-hij`.
        static func code(inPath path: String) -> String? {
            guard let first = path.split(separator: "/").first else { return nil }
            let parts = first.split(separator: "-").map(\.count)
            guard parts == [3, 4, 3], first.allSatisfy({ $0.isLowercase || $0 == "-" }) else { return nil }
            return String(first)
        }

        /// The words a name may carry in lower case: "Ana de la Cruz".
        static let nameParticles: Set<String> = ["de", "la", "le", "da", "di", "du", "del", "der", "den", "van", "von", "bin", "al"]

        /// A tile's other text is Meet's own: the meeting code
        /// (`abc-defg-hij`), icon labels (`mic_off`), "Pinned for yourself",
        /// a presenter's "(Presentation)" tile, "2 others". Each word of a
        /// name starts with a capital, or with a letter that has no case,
        /// the particles aside.
        static func isName(_ text: String) -> Bool {
            let words = text.split(separator: " ")
            guard !words.isEmpty, words.count <= nameMaxWords else { return false }
            let capitalised = words.filter { $0.first.map { $0.isLetter && !$0.isLowercase } ?? false }
            return !capitalised.isEmpty && words.allSatisfy { word in
                capitalised.contains(word) || nameParticles.contains(word.lowercased())
            }
        }
    }

    static func meet(_ nodes: [AXNode]) -> RosterReading {
        var reading = RosterReading()
        for i in tileRoots(nodes, target: .meet) {
            let tile = nodes[i..<subtreeEnd(of: i, in: nodes)]
            guard let name = tile.lazy.filter({ $0.role == "AXStaticText" }).flatMap(\.texts)
                .first(where: { $0 != Meet.selfLabel && Meet.isName($0) }) else { continue }
            if !reading.roster.contains(name) { reading.roster.append(name) }
            if nodes[i].domClasses.contains(Meet.speakingClass) { reading.speaking.insert(name) }
        }
        return reading
    }

    /// The participant tiles among `nodes`, by index: what `Roster` re-reads
    /// between walks of the whole window.
    static func tileRoots(_ nodes: [AXNode], target: Roster.Target) -> [Int] {
        nodes.indices.filter { i in
            switch target {
            case .meet:
                return nodes[i].domClasses.contains(Meet.tileClass)
            case .slackHuddle:
                guard let id = nodes[i].domIdentifier else { return false }
                return id.hasPrefix(Slack.tilePrefix) && !id.contains(Slack.tileDescriptionSuffix)
            }
        }
    }

    // MARK: The flattened tree

    /// One past the last descendant of `nodes[i]`: everything after it
    /// deeper than it belongs to it.
    static func subtreeEnd(of i: Int, in nodes: [AXNode]) -> Int {
        var end = i + 1
        while end < nodes.count, nodes[end].depth > nodes[i].depth { end += 1 }
        return end
    }
}
