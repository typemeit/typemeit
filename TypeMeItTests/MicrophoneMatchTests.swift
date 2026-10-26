import Testing
@testable import TypeMeIt

struct MicrophoneMatchTests {
    private let desk = AudioCapture.Device(id: "AppleUSBAudioEngine:Acme:Desk Mic:1100000:1", name: "Desk Mic")
    private let builtIn = AudioCapture.Device(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")

    @Test func aMicBackUnderANewUIDIsFoundByName() {
        let movedDesk = AudioCapture.Device(id: "AppleUSBAudioEngine:Acme:Desk Mic:2200000:1", name: "Desk Mic")
        #expect(AudioCapture.uid(named: "Desk Mic", among: [builtIn, movedDesk]) == movedDesk.id)
    }

    @Test func noInputWithTheNameFindsNothing() {
        #expect(AudioCapture.uid(named: "Desk Mic", among: [builtIn]) == nil)
    }

    /// Two of the same model share a name; guessing could record the wrong one.
    @Test func twoInputsWithTheNameFindNothing() {
        let secondDesk = AudioCapture.Device(id: "AppleUSBAudioEngine:Acme:Desk Mic:3300000:1", name: "Desk Mic")
        #expect(AudioCapture.uid(named: "Desk Mic", among: [desk, secondDesk, builtIn]) == nil)
    }

    @Test func theNameMustMatchExactly() {
        #expect(AudioCapture.uid(named: "Desk", among: [desk, builtIn]) == nil)
    }
}
