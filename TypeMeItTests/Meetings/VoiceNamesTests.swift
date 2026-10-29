import Foundation
import Testing
@testable import TypeMeIt

struct VoiceNamesTests {
    // MARK: Clips

    @Test func aSpanIsCutIntoWindowsAndAShortTailJoinsTheLast() {
        #expect(VoiceNames.windows(0..<23_000, longestMs: 10_000, shortestMs: 1_500) == [0..<10_000, 10_000..<20_000, 20_000..<23_000])
        #expect(VoiceNames.windows(0..<21_000, longestMs: 10_000, shortestMs: 1_500) == [0..<10_000, 10_000..<21_000])
        #expect(VoiceNames.windows(0..<1_000, longestMs: 10_000, shortestMs: 1_500) == [])
    }

    @Test func aClipIsRepeatedToFillTheWindowAndALongOneCut() {
        #expect(Diarizer.tiled([1, 2, 3], length: 7) == [1, 2, 3, 1, 2, 3, 1])
        #expect(Diarizer.tiled([1, 2, 3, 4], length: 3) == [1, 2, 3])
    }

    private func call(echo: Meeting.Echo, paragraphs: [(String, Int, Int)]) -> Meeting {
        var meeting = MeetingFixtures.example
        meeting.echo = echo
        meeting.paragraphs = paragraphs.map { Meeting.Paragraph(speaker: $0.0, startMs: $0.1, endMs: $0.2, text: "") }
        return meeting
    }

    private func clips(_ meeting: Meeting) -> [VoiceNames.Clip] {
        VoiceNames.clips(of: meeting, longestMs: 10_000, shortestMs: 1_500, crosstalkShare: 0.1, echoPadMs: 500)
    }

    @Test func eachVoiceIsCutFromTheTrackItIsHeardOn() {
        let meeting = call(echo: .clean, paragraphs: [("you", 0, 5_000), ("s1", 10_000, 15_000), ("r1", 20_000, 25_000)])
        #expect(clips(meeting) == [
            VoiceNames.Clip(speaker: "you", role: .mic, range: 0..<5_000),
            VoiceNames.Clip(speaker: "s1", role: .others, range: 10_000..<15_000),
            VoiceNames.Clip(speaker: "r1", role: .mic, range: 20_000..<25_000),
        ])
    }

    @Test func aClipAnotherVoiceTalksOverIsLeftOut() {
        // The far end covers half of the user's paragraph on the mic.
        let meeting = call(echo: .clean, paragraphs: [("you", 0, 4_000), ("s1", 2_000, 6_000)])
        #expect(clips(meeting) == [VoiceNames.Clip(speaker: "s1", role: .others, range: 2_000..<6_000)])
    }

    @Test func onAnEchoCallTheFarEndIsAlsoTakenFromTheMic() {
        let meeting = call(echo: .affected, paragraphs: [("you", 0, 3_000), ("s1", 3_200, 6_000), ("s1", 10_000, 14_000)])
        // The first far-end paragraph is within 500 ms of the user's, so only the second is echo.
        #expect(clips(meeting) == [
            VoiceNames.Clip(speaker: "you", role: .mic, range: 0..<3_000),
            VoiceNames.Clip(speaker: "s1", role: .others, range: 3_200..<6_000),
            VoiceNames.Clip(speaker: "s1", role: .others, range: 10_000..<14_000),
            VoiceNames.Clip(speaker: "s1", role: .mic, range: 10_000..<14_000),
        ])
    }

    @Test func aRoomMeetingCutsEveryVoiceFromTheRoomTrack() {
        var meeting = MeetingFixtures.example
        meeting.kind = .room
        meeting.tracks = [Meeting.Track(role: .room, file: "room.m4a", frames: 0)]
        meeting.paragraphs = [Meeting.Paragraph(speaker: "s1", startMs: 0, endMs: 3_000, text: ""), Meeting.Paragraph(speaker: "s2", startMs: 3_000, endMs: 6_000, text: "")]
        #expect(clips(meeting) == [
            VoiceNames.Clip(speaker: "s1", role: .room, range: 0..<3_000),
            VoiceNames.Clip(speaker: "s2", role: .room, range: 3_000..<6_000),
        ])
    }

    // MARK: Labels

    @Test func theUserAndNamedSpeakersAreLearnedAndNumberedOnesAreNot() {
        #expect(VoiceNames.label(of: Meeting.Speaker(id: "you", name: "You", isYou: true, talkMs: 0)) == VoiceNames.youName)
        #expect(VoiceNames.label(of: Meeting.Speaker(id: "s1", name: "Speaker 1", isYou: false, talkMs: 0)) == nil)
        #expect(VoiceNames.label(of: Meeting.Speaker(id: "s2", name: " Ana ", isYou: false, talkMs: 0, nameSource: .user)) == "Ana")
        #expect(VoiceNames.label(of: Meeting.Speaker(id: "s3", name: "Bo", isYou: false, talkMs: 0, nameSource: .speaking)) == "Bo")
    }

    @Test func aMergedSpeakersClipsGoToTheSpeakerHoldingItsParagraphs() {
        var meeting = call(echo: .clean, paragraphs: [("s1", 0, 5_000), ("s1", 10_000, 15_000)])
        meeting.speakers = [Meeting.Speaker(id: "s1", name: "Ana", isYou: false, talkMs: 0, nameSource: .user)]
        meeting.paragraphs[1].mergedFrom = "s2"
        let regrouped = VoiceNames.regrouped(["s1": [[1, 0]], "s2": [[0, 1]], "s3": [[1, 1]]], in: meeting)
        #expect(regrouped == ["s1": [[1, 0], [0, 1]]])
    }

    // MARK: Model

    /// A voice near one of four directions, wobbled by a fixed sequence.
    private struct Voices {
        private var state: UInt64 = 42
        mutating func near(_ axis: Int, spread: Float = 0.3) -> [Float] {
            var vector = [Float](repeating: 0, count: 4)
            vector[axis] = 1
            for i in vector.indices {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                vector[i] += spread * (Float(state >> 40) / Float(1 << 24) - 0.5)
            }
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return vector.map { $0 / norm }
        }
    }

    private func trained() -> (VoiceNames.Model, Voices) {
        var voices = Voices()
        var examples: [(name: String, vector: [Float])] = []
        for _ in 0..<40 { examples.append(("Ana", voices.near(0))) }
        for _ in 0..<10 { examples.append(("Bo", voices.near(1))) }
        for _ in 0..<200 { examples.append((VoiceNames.youName, voices.near(2))) }
        return (VoiceNames.Model.train(examples, steps: 300, rate: 4, momentum: 0.9)!, voices)
    }

    @Test func aKnownVoiceIsNamedAndAStrangerIsNot() {
        var (model, voices) = trained()
        let bo = model.posterior((0..<5).map { _ in voices.near(1) })
        #expect(model.names[bo.indices.max { bo[$0] < bo[$1] }!] == "Bo")
        #expect(bo.max()! >= 0.5)
        // The fourth direction is nobody it has heard.
        #expect(model.posterior((0..<5).map { _ in voices.near(3) }).max()! < 0.5)
    }

    @Test func oneVoiceIsNotEnoughToTellApart() {
        #expect(VoiceNames.Model.train([("Ana", [1, 0]), ("ana", [0.9, 0.1])], steps: 10, rate: 4, momentum: 0.9) == nil)
    }

    @Test func theLikeliestPersonIsGivenHoweverUnsureButNotFromTooFewClips() {
        var (model, voices) = trained()
        let heard: [String: [[Float]]] = [
            "s1": (0..<5).map { _ in voices.near(1) },
            "s2": (0..<5).map { _ in voices.near(3) },
            "s3": (0..<2).map { _ in voices.near(0) },
        ]
        let guesses = VoiceNames.likeliest(for: heard, model: model, minimumClips: 3)
        #expect(guesses.keys.sorted() == ["s1", "s2"])
        #expect(guesses["s1"]!.name == "Bo")
        #expect(guesses["s1"]!.posterior >= 0.5)
        // A stranger still gets their likeliest person, with the posterior that says how unsure.
        #expect(guesses["s2"]!.posterior < 0.5)
    }

    @Test func aNameGoesToTheLikelierSpeakerOnlyAndNeverOneAlreadyTaken() {
        var (model, voices) = trained()
        let heard: [String: [[Float]]] = [
            "s1": (0..<5).map { _ in voices.near(0, spread: 0.1) },
            "s2": (0..<5).map { _ in voices.near(0, spread: 0.6) },
            "s3": (0..<5).map { _ in voices.near(1) },
            "s4": (0..<2).map { _ in voices.near(2) },
        ]
        #expect(VoiceNames.suggestions(for: heard, taken: [], model: model, minimum: 0.5, minimumClips: 3) == ["s1": "Ana", "s3": "Bo"])
        #expect(VoiceNames.suggestions(for: heard, taken: ["bo"], model: model, minimum: 0.5, minimumClips: 3) == ["s1": "Ana"])
    }
}
