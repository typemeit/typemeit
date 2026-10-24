import Testing
@testable import TypeMeIt

private let builtIn = MeetingCapture.Device(uid: "built-in-mic", name: "Built-in Microphone", bluetooth: false)
private let speakers = MeetingCapture.Device(uid: "built-in-speakers", name: "Built-in Speakers", bluetooth: false)
private let headset = MeetingCapture.Device(uid: "headset", name: "Headset", bluetooth: true)
private let usbMic = MeetingCapture.Device(uid: "usb-mic", name: "USB Microphone", bluetooth: false)

struct MeetingCaptureTests {
    @Test func aCallRecordsTheBuiltInMicInPlaceOfTheDefaultHeadset() {
        #expect(MeetingCapture.microphone(picked: nil, defaultInput: headset, builtIn: builtIn, room: false) == builtIn)
    }

    @Test func aCallRecordsTheBuiltInMicEvenWhenTheHeadsetWasPicked() {
        #expect(MeetingCapture.microphone(picked: headset, defaultInput: builtIn, builtIn: builtIn, room: false) == builtIn)
    }

    @Test func aRoomRecordsTheBuiltInMicInPlaceOfTheDefaultHeadset() {
        #expect(MeetingCapture.microphone(picked: nil, defaultInput: headset, builtIn: builtIn, room: true) == builtIn)
    }

    @Test func aRoomKeepsAHeadsetTheUserPicked() {
        #expect(MeetingCapture.microphone(picked: headset, defaultInput: builtIn, builtIn: builtIn, room: true) == headset)
    }

    /// No built-in mic, or the lid is closed (`builtInMicrophone` is nil for both).
    @Test func aCallWithNoUsableBuiltInMicKeepsTheHeadset() {
        #expect(MeetingCapture.microphone(picked: nil, defaultInput: headset, builtIn: nil, room: false) == headset)
    }

    @Test func aRoomWithNoUsableBuiltInMicKeepsTheDefaultHeadset() {
        #expect(MeetingCapture.microphone(picked: nil, defaultInput: headset, builtIn: nil, room: true) == headset)
    }

    @Test func aPickedWiredMicBeatsTheDefault() {
        #expect(MeetingCapture.microphone(picked: usbMic, defaultInput: headset, builtIn: builtIn, room: false) == usbMic)
    }

    @Test func noPickAndNoDefaultFallsBackToTheBuiltInMic() {
        #expect(MeetingCapture.microphone(picked: nil, defaultInput: nil, builtIn: builtIn, room: false) == builtIn)
    }

    @Test func wiredSpeakersClockTheCall() {
        #expect(MeetingCapture.clockUID(mic: builtIn, output: speakers) == speakers.uid)
    }

    @Test func aBluetoothOutputLeavesTheMicAsTheClock() {
        #expect(MeetingCapture.clockUID(mic: builtIn, output: headset) == builtIn.uid)
    }

    @Test func noTapMeansTheMicIsTheClock() {
        #expect(MeetingCapture.clockUID(mic: usbMic, output: nil) == usbMic.uid)
    }
}
