import Foundation

/// Which elements of a meeting window are names, which say who is
/// speaking, and which are caption lines, per app (docs/meetings.md 8.6,
/// 9.2). Pure over the flattened tree. Each rule names what it anchors on
/// and where that was seen working; a rule that stops matching yields
/// nothing rather than a wrong name, and alignment then leaves numbers.
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
        for i in nodes.indices {
            guard let id = nodes[i].domIdentifier, id.hasPrefix(Slack.tilePrefix), !id.contains(Slack.tileDescriptionSuffix) else { continue }
            let tile = nodes[i..<subtreeEnd(of: i, in: nodes)]
            guard !id.contains(Slack.selfMarker),
                  let name = tile.lazy.flatMap(\.texts).compactMap(Slack.name(fromProfile:)).first else { continue }
            if !reading.roster.contains(name) { reading.roster.append(name) }
            if tile.contains(where: { $0.domClasses.contains(Slack.speakingClass) }) { reading.speaking.insert(name) }
        }
        return reading
    }

    // MARK: Meet

    /// Meet's classes are generated and change with deploys; its roles and
    /// labels do not. Observed working on 23 September 2026 by
    /// attendee-labs/attendee (`google_meet_chromedriver_payload.js`) and
    /// Vexa-ai/vexa (`gmeet-speakers.ts`, Apache-2.0): a participant's name
    /// is the text of a `notranslate` span in their tile; a tile rendered
    /// as speaking carries one of `speakingClasses` on itself or inside it;
    /// captions sit in a region labelled `Captions`, each turn's speaker in
    /// `NWpY1d` and its words in `ygicle`. The class names are the part
    /// that rots, so each is a list, and a miss yields nothing.
    enum Meet {
        static let nameClass = "notranslate"
        static let speakingClasses: Set<String> = ["Oaajhc", "HX2H7", "wEsLMd", "OgVli"]
        static let captionsLabel = "Captions"
        static let captionSpeakerClass = "NWpY1d"
        static let captionTextClass = "ygicle"
        /// A name is a few words; anything longer in a `notranslate` span is
        /// something else Meet declined to translate.
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

        /// Meet's own meeting code (`abc-defg-hij`), its icons' labels
        /// (`mic_off`, `call_end`) and some of its own words ("Pinned for
        /// yourself", which titled a meeting on 25 September) are
        /// `notranslate` too. Each word of a name starts with a capital, or
        /// with a letter that has no case, the particles aside.
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
        func names(in range: Range<Int>) -> [String] {
            var out: [String] = []
            for k in range where nodes[k].domClasses.contains(Meet.nameClass) {
                for text in text(of: k, in: nodes) where Meet.isName(text) && !out.contains(text) { out.append(text) }
            }
            return out
        }
        reading.roster = names(in: nodes.indices)

        // The speaking class sits on a tile or inside it: climb from it to the
        // smallest enclosing element that names exactly one person.
        let parents = parentIndices(nodes)
        for i in nodes.indices where !Meet.speakingClasses.isDisjoint(with: nodes[i].domClasses) {
            var at: Int? = i
            while let a = at {
                let found = names(in: a..<subtreeEnd(of: a, in: nodes))
                if found.count == 1 { reading.speaking.insert(found[0]); break }
                if found.count > 1 { break }
                at = parents[a]
            }
        }

        if let region = nodes.firstIndex(where: { $0.description == Meet.captionsLabel || $0.title == Meet.captionsLabel }) {
            var speaker: String?
            for k in (region + 1)..<subtreeEnd(of: region, in: nodes) {
                if nodes[k].domClasses.contains(Meet.captionSpeakerClass) {
                    speaker = text(of: k, in: nodes).first
                } else if nodes[k].domClasses.contains(Meet.captionTextClass), let speaker {
                    let words = nodes[k..<subtreeEnd(of: k, in: nodes)].flatMap(\.texts)
                    let line = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { reading.captions.append(RosterReading.Caption(name: speaker, text: line)) }
                }
            }
        }
        return reading
    }

    // MARK: The flattened tree

    /// One past the last descendant of `nodes[i]`: everything after it
    /// deeper than it belongs to it.
    static func subtreeEnd(of i: Int, in nodes: [AXNode]) -> Int {
        var end = i + 1
        while end < nodes.count, nodes[end].depth > nodes[i].depth { end += 1 }
        return end
    }

    /// The descendants of `nodes[i]`.
    static func subtree(of i: Int, in nodes: [AXNode]) -> ArraySlice<AXNode> {
        nodes[(i + 1)..<subtreeEnd(of: i, in: nodes)]
    }

    /// The index of each node's parent, nil for a root.
    static func parentIndices(_ nodes: [AXNode]) -> [Int?] {
        var stack: [Int] = []
        return nodes.indices.map { i in
            while let last = stack.last, nodes[last].depth >= nodes[i].depth { stack.removeLast() }
            defer { stack.append(i) }
            return stack.last
        }
    }

    /// A span's text is often its first descendant's rather than its own.
    static func text(of i: Int, in nodes: [AXNode]) -> [String] {
        if !nodes[i].texts.isEmpty { return nodes[i].texts }
        return subtree(of: i, in: nodes).first(where: { !$0.texts.isEmpty })?.texts ?? []
    }
}
