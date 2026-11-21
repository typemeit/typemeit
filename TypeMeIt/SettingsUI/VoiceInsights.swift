import SwiftUI

/// The voices tab of the insights page: every learned clip a square dot, laid
/// out so clips that sound alike sit together, in the colour its person
/// has in meetings, beside the people they belong to. Pointing at a
/// person, on the map or in the list, fades everyone else; a click keeps
/// them, and half-fades the people their voice sits nearest. A click on a
/// dot also plays its clip and offers its speaker's names. Pinch to zoom,
/// drag to move, double-click to fit.
struct VoiceInsights: View {
    /// A newer map is being made; the last one shows meanwhile.
    @Binding var updating: Bool
    @State private var settings = Settings.shared
    @State private var store = MeetingStore.shared
    @State private var map: VoiceMap?
    /// How far relearning old meetings' clip times has got; nil when none
    /// are being relearned.
    @State private var relearned: Double?
    @State private var hovered: Int?
    @State private var pinned: Int?
    /// The dot clicked, whose clip plays in the panel beside the map.
    @State private var heard: VoiceMap.Dot?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let dot: CGFloat = 3
    /// How near the pointer has to be to a dot to point at its person.
    private static let reach: CGFloat = 8
    /// People named on the map until one is pointed at.
    private static let labelled = 10
    /// People left half-faded beside the one kept.
    private static let nearestShown = 3
    private static let listWidth: CGFloat = 300
    private static let faded = 0.12
    private static let halfFaded = 0.5

    private var shown: Int? { pinned ?? hovered }

    var body: some View {
        Group {
            if !settings.meetingLearnVoices {
                note("learn voices is off")
            } else if relearned != nil || (map == nil && updating) {
                SquarePuffLoader(fraction: relearned)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let map {
                let colours = VoiceInsights.colours(map)
                HStack(spacing: 0) {
                    canvas(map, colours: colours)
                    Rectangle().fill(DesignTokens.Colors.inkA20).frame(width: DesignTokens.hairline)
                    Group {
                        if let source = heard?.source {
                            ScrollView { VoiceClipPanel(source: source, close: { heard = nil }) }
                        } else {
                            ScrollView { list(map, colours: colours) }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: VoiceInsights.listWidth)
                }
                .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
                .padding([.horizontal, .bottom], 20)
            } else {
                note("name people in two meetings to see their voices")
            }
        }
        .task(id: [store.revision, settings.meetingLearnVoices ? 1 : 0]) {
            guard settings.meetingLearnVoices else { map = nil; return }
            if map == nil { map = await VoiceLibrary.shared.lastMap() }
            updating = true
            defer { updating = false; relearned = nil }
            let untimed = await VoiceLibrary.shared.untimed(store.meetings.compactMap { meeting in
                store.folder(for: meeting.id).map { (meeting: meeting, folder: $0) }
            })
            for (done, old) in untimed.enumerated() {
                relearned = Double(done) / Double(untimed.count)
                await VoiceLibrary.shared.learn(old.meeting, folder: old.folder)
                guard !Task.isCancelled else { return }
            }
            relearned = nil
            let made = await VoiceLibrary.shared.map(among: store.meetings)
            guard !Task.isCancelled else { return }
            if made != map { pinned = nil; hovered = nil; heard = nil }
            map = made
        }
    }

    /// Each person's colour as meetings draw it: you in ink, everyone else
    /// in the hue their name picks.
    static func colours(_ map: VoiceMap) -> [Color] {
        map.people.map { person in
            person.name == VoiceNames.youName ? DesignTokens.Colors.ink : Color(nsColor: MeetingFingerprint.hue(for: person.name).color)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Map

    /// Where a dot lands: the map's unit square fitted into `size`, then zoomed and moved.
    private func place(_ x: Float, _ y: Float, in size: CGSize) -> CGPoint {
        let side = min(size.width, size.height) - 40
        let scale = zoom * pinch
        return CGPoint(x: size.width / 2 + (CGFloat(x) - 0.5) * side * scale + pan.width + drag.width,
                       y: size.height / 2 + (CGFloat(y) - 0.5) * side * scale + pan.height + drag.height)
    }

    private func dot(at point: CGPoint, in map: VoiceMap, size: CGSize) -> VoiceMap.Dot? {
        var best: (distance: CGFloat, dot: VoiceMap.Dot)?
        for dot in map.dots {
            let at = place(dot.x, dot.y, in: size)
            let distance = hypot(at.x - point.x, at.y - point.y)
            if distance <= VoiceInsights.reach, distance < best?.distance ?? .infinity { best = (distance, dot) }
        }
        return best?.dot
    }

    /// How much of a person's colour shows: all of it with no one pointed
    /// at, or for the one pointed at; half for those nearest the one kept.
    private func opacity(_ person: Int, near: Set<Int>) -> Double {
        guard let shown, person != shown else { return 1 }
        return pinned != nil && near.contains(person) ? VoiceInsights.halfFaded : VoiceInsights.faded
    }

    private func canvas(_ map: VoiceMap, colours: [Color]) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let near = Set(shown.map { map.people[$0].nearest.prefix(VoiceInsights.nearestShown).map(\.person) } ?? [])
            Canvas { context, size in
                // Faded first, so the people shown are drawn over the rest.
                let order = map.dots.indices.sorted { opacity(map.dots[$0].person, near: near) < opacity(map.dots[$1].person, near: near) }
                for index in order {
                    let dot = map.dots[index]
                    let at = place(dot.x, dot.y, in: size)
                    let rect = CGRect(x: at.x - VoiceInsights.dot / 2, y: at.y - VoiceInsights.dot / 2, width: VoiceInsights.dot, height: VoiceInsights.dot)
                    context.fill(Path(rect), with: .color(colours[dot.person].opacity(opacity(dot.person, near: near))))
                }
                let named = shown.map { [$0] + (pinned != nil ? Array(near) : []) } ?? Array(map.people.indices.prefix(VoiceInsights.labelled))
                for index in named {
                    let person = map.people[index]
                    let text = Text(person.name).font(Square.mono(10)).foregroundStyle(DesignTokens.Colors.ink)
                    context.draw(text, at: place(person.x, person.y, in: size))
                }
                if let heard {
                    let at = place(heard.x, heard.y, in: size)
                    let ring = VoiceInsights.dot * 3
                    context.stroke(Path(CGRect(x: at.x - ring / 2, y: at.y - ring / 2, width: ring, height: ring)),
                                   with: .color(DesignTokens.Colors.ink), lineWidth: DesignTokens.hairline)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case .active(let at) = phase else { hovered = nil; return }
                hovered = dot(at: at, in: map, size: size)?.person
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { _ in withAnimation(.snappy) { zoom = 1; pan = .zero } }
                    .exclusively(before: SpatialTapGesture().onEnded { tap in
                        let picked = dot(at: tap.location, in: map, size: size)
                        heard = picked
                        pinned = picked?.person
                    })
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = max(1, zoom * value.magnification) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in pan.width += value.translation.width; pan.height += value.translation.height }
            )
        }
        .clipped()
    }

    // MARK: List

    private func list(_ map: VoiceMap, colours: [Color]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(map.people.enumerated()), id: \.offset) { index, person in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Rectangle().fill(colours[index]).frame(width: 8, height: 8)
                        Text(person.name).font(Square.sans(12)).lineLimit(1)
                        Spacer()
                        Text(counted(person.clips, "clip")).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
                        Text(VoiceInsights.percent(person.apart))
                            .font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink2)
                            .frame(width: 36, alignment: .trailing)
                            .help("share of each clip's \(Fixed.voiceMapNeighbours) nearest clips that are theirs")
                    }
                    if pinned == index, !person.nearest.isEmpty {
                        Text("sounds like: " + person.nearest.prefix(VoiceInsights.nearestShown)
                            .map { "\(map.people[$0.person].name) \(VoiceInsights.percent($0.share))" }.joined(separator: " · "))
                            .font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(pinned == index ? DesignTokens.Colors.inkA12 : hovered == index ? DesignTokens.Colors.inkA08 : .clear)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                .onTapGesture { pinned = pinned == index ? nil : index; heard = nil }
            }
        }
    }

    private static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}

/// A clicked dot: the meeting it was heard in, its clip playing, and the
/// meeting page's names for its speaker, so a voice learned under the
/// wrong name can be heard and given the right one there and then. The
/// name goes to the speaker in that meeting, as on the meeting page.
private struct VoiceClipPanel: View {
    let source: VoiceMap.Source
    let close: () -> Void
    @State private var store = MeetingStore.shared
    @State private var player = RecordingPlayer.shared
    @State private var name = ""
    @State private var focused = true
    @State private var pick = 0
    @State private var clip = 0
    @State private var past: [SpeakerAssign.Person] = []

    private var meeting: Meeting? { store.meeting(source.meeting) }

    private var audioURLs: [URL]? {
        guard let meeting, !meeting.audioFiles.isEmpty, let folder = store.folder(for: meeting.id) else { return nil }
        return meeting.audioFiles.map { folder.appendingPathComponent($0) }
    }

    /// The dot's own clip first, with the words said over it, then the
    /// speaker's clips the meeting page would play.
    private var clips: [SpeakerAssign.Clip] {
        guard let meeting else { return [] }
        var own: [SpeakerAssign.Clip] = []
        if let start = source.startMs, let end = source.endMs {
            let words = meeting.paragraphs.filter { $0.startMs < end && $0.endMs > start }.map(\.text).joined(separator: " ")
            own = [SpeakerAssign.Clip(startMs: start, endMs: end, text: words)]
        }
        return own + SpeakerAssign.clips(for: source.speaker, in: meeting)
    }

    private var options: [SpeakerAssign.Option] {
        guard let meeting else { return [] }
        return SpeakerAssign.options(for: source.speaker, in: meeting, query: name, past: past)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("‹ people", action: close).buttonStyle(.plain)
                .font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
            if let meeting, let speaker = meeting.speakers.first(where: { $0.id == source.speaker }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(Square.sans(12)).lineLimit(2)
                    Text(meeting.started.formatted(date: .abbreviated, time: .shortened))
                        .font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
                }
                SquareTextInput(placeholder: speaker.name, text: $name, font: Square.appKitMono(12), focused: $focused,
                                onSubmit: { if options.indices.contains(pick) { choose(options[pick]) } },
                                onCancel: close, onCommand: command)
                    .padding(.horizontal, 5)
                    .frame(height: 24)
                    .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
                if audioURLs == nil {
                    Text("audio not kept").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
                }
                SpeakerNames(meetingID: meeting.id, clips: clips, clip: clip, options: options, pick: pick,
                             play: { clip = $0; play() }, choose: choose)
            } else {
                Text("meeting deleted").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
            }
        }
        .padding(14)
        .onChange(of: name) { _, _ in pick = 0 }
        .task(id: source) {
            clip = 0
            name = ""
            pick = 0
            if let meeting { past = SpeakerAssign.past(store.meetings, for: meeting) }
            play()
        }
        .onDisappear { if player.playing == source.meeting { player.pause() } }
    }

    private func play() {
        guard clips.indices.contains(clip), let urls = audioURLs else { return }
        let current = clips[clip]
        player.play(id: source.meeting, urls: urls, from: Double(current.startMs) / 1000, until: Double(current.endMs) / 1000)
    }

    private func choose(_ option: SpeakerAssign.Option) {
        _ = store.assign(option.choice, to: source.speaker, in: source.meeting)
        close()
    }

    /// ↑↓ move through the names.
    private func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): pick = min(pick + 1, max(options.count - 1, 0))
        case #selector(NSResponder.moveUp(_:)): pick = max(pick - 1, 0)
        default: return false
        }
        return true
    }
}
