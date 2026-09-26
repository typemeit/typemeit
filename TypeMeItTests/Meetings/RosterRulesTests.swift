import Testing
@testable import TypeMeIt

struct RosterRulesTests {
    private func node(_ depth: Int, _ role: String = "AXGroup", title: String? = nil, description: String? = nil, value: String? = nil, id: String? = nil, classes: [String] = []) -> AXNode {
        AXNode(depth: depth, role: role, title: title, description: description, value: value, domIdentifier: id, domClasses: classes)
    }

    // MARK: Slack

    private func slackTile(_ depth: Int, session: String, user: String, name: String, speaking: Bool) -> [AXNode] {
        [
            node(depth, description: "View \(name)'s profile", id: "huddle-grid-gridcell-\(session)_\(user)"),
            node(depth + 1, classes: speaking ? ["p-huddle_peer_tile__overlay", RosterRules.Slack.speakingClass] : ["p-huddle_peer_tile__overlay"]),
            node(depth + 2, "AXStaticText", value: name),
        ]
    }

    @Test func slackReadsNamesAndTheSpeakerAndSkipsTheUser() {
        let nodes = [node(0, "AXWindow", title: "Huddle in #design")]
            + slackTile(1, session: "self", user: "U0AAAAAAAAA", name: "Max Mitchell", speaking: false)
            + slackTile(1, session: "9f2c", user: "U0BBBBBBBBB", name: "Ana Lopez", speaking: true)
            + slackTile(1, session: "7a1e", user: "U0CCCCCCCCC", name: "Ben Ode", speaking: false)
        #expect(RosterRules.slack(nodes) == RosterReading(roster: ["Ana Lopez", "Ben Ode"], speaking: ["Ana Lopez"], captions: [], channel: "#design"))
    }

    @Test func slackIgnoresTheOffscreenDescriptionNode() {
        let nodes = [node(0, description: "View Ana Lopez's profile", id: "huddle-grid-gridcell-9f2c_U0BBBBBBBBB-a11y_huddle_peer_tile_description")]
        #expect(RosterRules.slack(nodes) == RosterReading())
    }

    @Test func slackProfileText() {
        #expect(RosterRules.Slack.name(fromProfile: "View Marlow Fenn's profile") == "Marlow Fenn")
        #expect(RosterRules.Slack.name(fromProfile: "Leave huddle") == nil)
    }

    // MARK: Meet

    /// A tile as the 25 September capture had it: the name six levels down,
    /// `kssMZb` on the tile and on one element inside it while its person speaks.
    private func meetTile(_ depth: Int, name: String, speaking: Bool) -> [AXNode] {
        let lit = speaking ? [RosterRules.Meet.speakingClass] : []
        return [
            node(depth, classes: [RosterRules.Meet.tileClass, "i8wGAe"] + lit + ["iPFm3e", "MVbbRb", "tSl2vc"]),
            node(depth + 1, classes: ["oZRSLe"]),
            node(depth + 1),
            node(depth + 2, classes: ["ZY8hPc", "iPFm3e"]),
            node(depth + 3, classes: ["OFfHfd", "urlhDe", "iPFm3e"]),
            node(depth + 4, classes: ["XEazBc", "adnwBd"]),
            node(depth + 5),
            node(depth + 6, "AXStaticText", value: name),
            node(depth + 2, classes: ["lH9pqf", "atLQQ", "iPFm3e"] + lit),
        ]
    }

    private func meetPage(_ tiles: [AXNode]) -> [AXNode] {
        [node(0, "AXWebArea", title: "Meet – vmt-xuvg-jgd"), node(1, "AXStaticText", value: "18:32"), node(1, "AXStaticText", value: "vmt-xuvg-jgd"),
         node(1, title: "Call feature notifications and actions"), node(2, "AXPopUpButton", title: "People"), node(1)] + tiles
    }

    @Test func meetReadsTileNamesAndTheSpeakingTile() {
        let nodes = meetPage(meetTile(2, name: "Ana Lopez", speaking: false) + meetTile(2, name: "Ben Ode", speaking: true))
        #expect(RosterRules.meet(nodes) == RosterReading(roster: ["Ana Lopez", "Ben Ode"], speaking: ["Ben Ode"], captions: [], channel: nil))
    }

    @Test func aTileWithoutAPersonsNameIsSkipped() {
        let nodes = meetPage(meetTile(2, name: "You", speaking: true) + meetTile(2, name: "Max Mitchell (Presentation)", speaking: false)
            + meetTile(2, name: "2 others", speaking: false))
        #expect(RosterRules.meet(nodes) == RosterReading())
    }

    @Test func theSpeakingClassOffATileNamesNobody() {
        let nodes = meetPage([node(2, classes: [RosterRules.Meet.speakingClass]), node(3, "AXStaticText", value: "Ana Lopez")])
        #expect(RosterRules.meet(nodes) == RosterReading())
    }

    @Test func tileRootsAreTheTilesAlone() {
        let meet = meetPage(meetTile(2, name: "Ana Lopez", speaking: false) + meetTile(2, name: "Ben Ode", speaking: true))
        #expect(RosterRules.tileRoots(meet, target: .meet) == [6, 15])
        let slack = [node(0, description: "View Ana Lopez's profile", id: "huddle-grid-gridcell-9f2c_U0BBBBBBBBB-a11y_huddle_peer_tile_description")]
            + slackTile(0, session: "9f2c", user: "U0BBBBBBBBB", name: "Ana Lopez", speaking: false)
        #expect(RosterRules.tileRoots(slack, target: .slackHuddle) == [1])
    }

    @Test func aTileReadOnItsOwnReadsTheSame() {
        // Between walks, Roster reads each tile's own subtree from depth 0.
        let nodes = meetTile(0, name: "Ana Lopez", speaking: true) + meetTile(0, name: "Ben Ode", speaking: false)
        #expect(RosterRules.meet(nodes) == RosterReading(roster: ["Ana Lopez", "Ben Ode"], speaking: ["Ana Lopez"], captions: [], channel: nil))
    }

    @Test func meetsOwnWordsAreNotNames() {
        #expect(!RosterRules.Meet.isName("abc-defg-hij"))
        #expect(!RosterRules.Meet.isName("mic_off"))
        #expect(!RosterRules.Meet.isName("arrow_drop_down"))
        #expect(!RosterRules.Meet.isName("Pinned for yourself"))
        #expect(!RosterRules.Meet.isName("Turn on microphone"))
        #expect(!RosterRules.Meet.isName("Max Mitchell (Presentation)"))
        #expect(RosterRules.Meet.isName("Ana de la Cruz"))
        #expect(RosterRules.Meet.isName("Jean-Luc O'Brien"))
        #expect(RosterRules.Meet.isName("李明"))
        #expect(RosterRules.Meet.isName("Ana Lopez"))
        #expect(!RosterRules.Meet.isName("one two three four five six"))
    }

    @Test func theMeetCodeComesFromTheAddressPath() {
        #expect(RosterRules.Meet.code(inPath: "/abc-defg-hij") == "abc-defg-hij")
        #expect(RosterRules.Meet.code(inPath: "/abc-defg-hij/extra") == "abc-defg-hij")
        #expect(RosterRules.Meet.code(inPath: "/landing") == nil)
        #expect(RosterRules.Meet.code(inPath: "/") == nil)
    }
}
