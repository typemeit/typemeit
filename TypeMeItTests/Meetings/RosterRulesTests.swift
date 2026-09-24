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

    private func meetTile(_ depth: Int, name: String, speaking: Bool) -> [AXNode] {
        [
            node(depth, classes: ["tile"]),
            node(depth + 1, classes: speaking ? ["ring", "Oaajhc"] : ["ring"]),
            node(depth + 1, classes: ["notranslate"]),
            node(depth + 2, "AXStaticText", value: name),
        ]
    }

    @Test func meetReadsTileNamesAndTheLitTile() {
        let nodes = [node(0, "AXWebArea", title: "Meet - abc-defg-hij")]
            + [node(1, classes: ["notranslate"]), node(2, "AXStaticText", value: "abc-defg-hij")]
            + meetTile(1, name: "Ana Lopez", speaking: false)
            + meetTile(1, name: "Ben Ode", speaking: true)
        #expect(RosterRules.meet(nodes) == RosterReading(roster: ["Ana Lopez", "Ben Ode"], speaking: ["Ben Ode"], captions: [], channel: nil))
    }

    @Test func aSpeakingClassAboveTwoTilesNamesNobody() {
        let nodes = [node(0, "AXWebArea"), node(1, classes: ["Oaajhc"])] + meetTile(2, name: "Ana Lopez", speaking: false) + meetTile(2, name: "Ben Ode", speaking: false)
        #expect(RosterRules.meet(nodes).speaking == [])
    }

    @Test func meetReadsCaptionTurns() {
        let nodes = [
            node(0, "AXWebArea"),
            node(1, description: "Captions"),
            node(2, classes: ["nMcdL"]),
            node(3, classes: ["NWpY1d"]), node(4, "AXStaticText", value: "Ana Lopez"),
            node(3, classes: ["ygicle"]), node(4, "AXStaticText", value: "so the plan is"), node(4, "AXStaticText", value: "to ship friday"),
            node(2, classes: ["nMcdL"]),
            node(3, classes: ["NWpY1d"]), node(4, "AXStaticText", value: "Ben Ode"),
            node(3, classes: ["ygicle"]), node(4, "AXStaticText", value: "sounds good"),
        ]
        #expect(RosterRules.meet(nodes).captions == [
            RosterReading.Caption(name: "Ana Lopez", text: "so the plan is to ship friday"),
            RosterReading.Caption(name: "Ben Ode", text: "sounds good"),
        ])
    }

    @Test func aMeetingCodeIsNotAName() {
        #expect(!RosterRules.Meet.isName("abc-defg-hij"))
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
