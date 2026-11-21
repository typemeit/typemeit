import Accelerate
import Foundation

/// The learned voices laid out flat for the voices page: one dot per clip,
/// placed by t-SNE so clips that sound alike sit together, and for each
/// person how often their clips' nearest clips are theirs, and whose they
/// are when not.
struct VoiceMap: Codable, Equatable, Sendable {
    struct Dot: Codable, Equatable, Sendable {
        var x: Float
        var y: Float
        /// Index into `people`.
        var person: Int
        var source: Source?
    }

    /// Where a clip was heard: the meeting, the speaker it belongs to there,
    /// and its time, when the voices were learned with times.
    struct Source: Codable, Equatable, Sendable {
        var meeting: UUID
        var speaker: String
        var startMs: Int?
        var endMs: Int?
    }

    /// One learned clip: whose it is, its embedding, and where it was heard.
    struct Example: Sendable {
        var name: String
        var vector: [Float]
        var source: Source? = nil
    }

    struct Person: Codable, Equatable, Sendable {
        var name: String
        /// Every clip learned of them; the map shows at most
        /// `Fixed.voiceMapClipsPerPerson`.
        var clips: Int
        /// Of each shown clip's `Fixed.voiceMapNeighbours` nearest clips, by
        /// the full embedding, the share that are this person's too.
        var apart: Double
        /// The other people their clips' nearest clips belong to, as
        /// indexes into `people` with their share, largest first.
        var nearest: [Neighbour]
        /// The middle of this person's dots, where their name is drawn.
        var x: Float
        var y: Float
    }

    struct Neighbour: Codable, Equatable, Sendable {
        var person: Int
        var share: Double
    }

    /// Dots in 0...1 on both axes.
    var dots: [Dot]
    /// Most clips first.
    var people: [Person]

    /// Nil without two people to tell apart. Each person's clips are
    /// thinned evenly to `Fixed.voiceMapClipsPerPerson`, so the layout's
    /// n² work stays a few seconds.
    static func make(_ examples: [Example]) -> VoiceMap? {
        guard let dimensions = examples.first?.vector.count, dimensions > 0 else { return nil }
        var byName: [String: [Example]] = [:]
        var spelling: [String: String] = [:]
        for example in examples where example.vector.count == dimensions {
            let key = example.name.lowercased()
            if spelling[key] == nil { spelling[key] = example.name }
            byName[key, default: []].append(example)
        }
        let keys = byName.keys.sorted { (byName[$0]!.count, $1) > (byName[$1]!.count, $0) }
        guard keys.count >= 2 else { return nil }

        var rows: [Float] = []
        var owners: [Int] = []
        var sources: [Source?] = []
        for (person, key) in keys.enumerated() {
            let clips = byName[key]!
            let kept = min(clips.count, Fixed.voiceMapClipsPerPerson)
            for i in 0..<kept {
                let clip = clips[i * clips.count / kept]
                var vector = clip.vector
                sources.append(clip.source)
                var norm: Float = 0
                vDSP_svesq(vector, 1, &norm, vDSP_Length(dimensions))
                var scale = 1 / max(norm.squareRoot(), .leastNormalMagnitude)
                vDSP_vsmul(vector, 1, &scale, &vector, 1, vDSP_Length(dimensions))
                rows += vector
                owners.append(person)
            }
        }
        let n = owners.count
        // Cosine similarity of every pair; the rows are unit length.
        var similarity = [Float](repeating: 0, count: n * n)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(n), Int32(dimensions),
                    1, rows, Int32(dimensions), rows, Int32(dimensions), 0, &similarity, Int32(n))

        guard let layout = tsne(similarity: similarity, count: n, rows: rows, dimensions: dimensions) else { return nil }
        let shares = neighbourShares(similarity: similarity, owners: owners, people: keys.count)

        var dots: [Dot] = []
        var xs = [[Float]](repeating: [], count: keys.count), ys = xs
        for i in 0..<n {
            dots.append(Dot(x: layout[2 * i], y: layout[2 * i + 1], person: owners[i], source: sources[i]))
            xs[owners[i]].append(layout[2 * i])
            ys[owners[i]].append(layout[2 * i + 1])
        }
        let people = keys.enumerated().map { person, key in
            let others = shares[person].enumerated().filter { $0.offset != person && $0.element > 0 }
                .sorted { $0.element > $1.element }
                .map { Neighbour(person: $0.offset, share: $0.element) }
            return Person(name: spelling[key]!, clips: byName[key]!.count, apart: shares[person][person], nearest: others,
                          x: median(xs[person]), y: median(ys[person]))
        }
        return VoiceMap(dots: dots, people: people)
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// `[a][b]`: of person a's clips' nearest clips, the share that are b's.
    static func neighbourShares(similarity: [Float], owners: [Int], people: Int) -> [[Double]] {
        let n = owners.count
        let k = min(Fixed.voiceMapNeighbours, n - 1)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: people), count: people)
        var total = [Int](repeating: 0, count: people)
        for i in 0..<n {
            let row = i * n
            // The k largest by insertion into a short sorted list.
            var best: [(similarity: Float, index: Int)] = []
            for j in 0..<n where j != i {
                let s = similarity[row + j]
                if best.count == k, s <= best[k - 1].similarity { continue }
                let at = best.firstIndex { s > $0.similarity } ?? best.count
                best.insert((s, j), at: at)
                if best.count > k { best.removeLast() }
            }
            for neighbour in best { counts[owners[i]][owners[neighbour.index]] += 1 }
            total[owners[i]] += best.count
        }
        return (0..<people).map { a in (0..<people).map { b in total[a] == 0 ? 0 : Double(counts[a][b]) / Double(total[a]) } }
    }

    /// Exact t-SNE (van der Maaten and Hinton 2008) with scikit-learn's
    /// defaults: perplexity 30, early exaggeration 12 for the first 250
    /// steps, learning rate n / 48, momentum 0.5 then 0.8, gains. Starts
    /// from the first two principal components, so the same clips always
    /// lay out the same. Each row's work is done with vDSP. Returns x, y
    /// pairs scaled into 0...1.
    static func tsne(similarity: [Float], count n: Int, rows: [Float], dimensions: Int) -> [Float]? {
        guard n > 2 else { return nil }
        let length = vDSP_Length(n)
        let perplexity = min(Fixed.voiceMapPerplexity, Float(n - 1) / 3)
        let target = logf(perplexity)
        var p = [Float](repeating: 0, count: n * n)
        // Squared distance between unit vectors is 2 - 2 cos.
        var distances = [Float](repeating: 0, count: n)
        var exps = [Float](repeating: 0, count: n)
        var count32 = Int32(n)
        for i in 0..<n {
            if Task.isCancelled { return nil }
            similarity.withUnsafeBufferPointer { s in
                var minusTwo: Float = -2, two: Float = 2
                vDSP_vsmsa(s.baseAddress! + i * n, 1, &minusTwo, &two, &distances, 1, length)
            }
            var low: Float = 0, high = Float.infinity, beta: Float = 1
            for _ in 0..<64 {
                var minusBeta = -beta
                vDSP_vsmul(distances, 1, &minusBeta, &exps, 1, length)
                vvexpf(&exps, exps, &count32)
                exps[i] = 0
                var sum: Float = 0, weighted: Float = 0
                vDSP_sve(exps, 1, &sum, length)
                vDSP_dotpr(distances, 1, exps, 1, &weighted, length)
                sum = max(sum, .leastNormalMagnitude)
                let entropy = logf(sum) + beta * weighted / sum
                if abs(entropy - target) < 1e-5 { break }
                if entropy > target { low = beta; beta = high.isInfinite ? beta * 2 : (beta + high) / 2 }
                else { high = beta; beta = (beta + low) / 2 }
            }
            var sum: Float = 0
            vDSP_sve(exps, 1, &sum, length)
            var inverse = 1 / max(sum, .leastNormalMagnitude)
            p.withUnsafeMutableBufferPointer { out in
                vDSP_vsmul(exps, 1, &inverse, out.baseAddress! + i * n, 1, length)
            }
        }
        // Joint P: (P + Pᵀ) / 2n, floored as scikit-learn does.
        var joint = [Float](repeating: 0, count: n * n)
        vDSP_mtrans(p, 1, &joint, 1, length, length)
        vDSP_vadd(p, 1, joint, 1, &joint, 1, vDSP_Length(n * n))
        var half = 1 / Float(2 * n), floor: Float = 1e-12, ceiling = Float.greatestFiniteMagnitude
        vDSP_vsmul(joint, 1, &half, &joint, 1, vDSP_Length(n * n))
        vDSP_vclip(joint, 1, &floor, &ceiling, &joint, 1, vDSP_Length(n * n))
        p = []

        let start = principalComponents(rows: rows, count: n, dimensions: dimensions)
        var x = (0..<n).map { start[2 * $0] }, y = (0..<n).map { start[2 * $0 + 1] }
        var stepX = [Float](repeating: 0, count: n), stepY = stepX
        var gainX = [Float](repeating: 1, count: n), gainY = gainX
        var gradX = [Float](repeating: 0, count: n), gradY = gradX
        var q = [Float](repeating: 0, count: n * n)
        var dx = [Float](repeating: 0, count: n), dy = dx, force = dx
        let rate = max(Float(n) / Fixed.voiceMapExaggeration / 4, 50)
        for iteration in 0..<Fixed.voiceMapSteps {
            if Task.isCancelled { return nil }
            let exaggerated = iteration < Fixed.voiceMapExaggeratedSteps
            var exaggeration: Float = exaggerated ? Fixed.voiceMapExaggeration : 1
            let momentum: Float = exaggerated ? 0.5 : 0.8
            // q[i][j] = 1 / (1 + |yi − yj|²), zero on the diagonal.
            q.withUnsafeMutableBufferPointer { q in
                for i in 0..<n {
                    let row = q.baseAddress! + i * n
                    var minusX = -x[i], minusY = -y[i], one: Float = 1
                    vDSP_vsadd(x, 1, &minusX, &dx, 1, length)
                    vDSP_vsadd(y, 1, &minusY, &dy, 1, length)
                    vDSP_vdist(dx, 1, dy, 1, row, 1, length)
                    vDSP_vsq(row, 1, row, 1, length)
                    vDSP_vsadd(row, 1, &one, row, 1, length)
                    vvrecf(row, row, &count32)
                    row[i] = 0
                }
            }
            var z: Float = 0
            vDSP_sve(q, 1, &z, vDSP_Length(n * n))
            var minusInverseZ = -1 / max(z, .leastNormalMagnitude)
            // Gradient: 4 Σj (e·pij − qij / Z) · qij · (yi − yj).
            for i in 0..<n {
                joint.withUnsafeBufferPointer { joint in
                    q.withUnsafeBufferPointer { q in
                        let qRow = q.baseAddress! + i * n
                        vDSP_vsmsma(joint.baseAddress! + i * n, 1, &exaggeration, qRow, 1, &minusInverseZ, &force, 1, length)
                        vDSP_vmul(force, 1, qRow, 1, &force, 1, length)
                    }
                }
                var forceSum: Float = 0, forceX: Float = 0, forceY: Float = 0
                vDSP_sve(force, 1, &forceSum, length)
                vDSP_dotpr(force, 1, x, 1, &forceX, length)
                vDSP_dotpr(force, 1, y, 1, &forceY, length)
                gradX[i] = 4 * (x[i] * forceSum - forceX)
                gradY[i] = 4 * (y[i] * forceSum - forceY)
            }
            for i in 0..<n {
                gainX[i] = (gradX[i] > 0) != (stepX[i] > 0) ? gainX[i] + 0.2 : max(gainX[i] * 0.8, 0.01)
                gainY[i] = (gradY[i] > 0) != (stepY[i] > 0) ? gainY[i] + 0.2 : max(gainY[i] * 0.8, 0.01)
                stepX[i] = momentum * stepX[i] - rate * gainX[i] * gradX[i]
                stepY[i] = momentum * stepY[i] - rate * gainY[i] * gradY[i]
                x[i] += stepX[i]
                y[i] += stepY[i]
            }
        }
        return normalised((0..<(2 * n)).map { $0.isMultiple(of: 2) ? x[$0 / 2] : y[$0 / 2] })
    }

    /// The rows projected on their first two principal components, found
    /// by power iteration, scaled to a spread of 1e-4 as scikit-learn's PCA
    /// start is.
    static func principalComponents(rows: [Float], count n: Int, dimensions d: Int) -> [Float] {
        var mean = [Float](repeating: 0, count: d)
        for i in 0..<n { for k in 0..<d { mean[k] += rows[i * d + k] / Float(n) } }
        var centred = rows
        for i in 0..<n { for k in 0..<d { centred[i * d + k] -= mean[k] } }
        var transposed = [Float](repeating: 0, count: d * n)
        vDSP_mtrans(centred, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))
        var components: [[Float]] = []
        var projected = [Float](repeating: 0, count: 2 * n)
        for c in 0..<2 {
            // A fixed start, so the layout repeats.
            var v = (0..<d).map { Float(($0 * 7 + c * 3) % 11) - 5 }
            var scores = [Float](repeating: 0, count: n)
            var next = [Float](repeating: 0, count: d)
            for _ in 0..<100 {
                vDSP_mmul(centred, 1, v, 1, &scores, 1, vDSP_Length(n), 1, vDSP_Length(d))
                vDSP_mmul(transposed, 1, scores, 1, &next, 1, vDSP_Length(d), 1, vDSP_Length(n))
                for previous in components {
                    var dot: Float = 0
                    vDSP_dotpr(next, 1, previous, 1, &dot, vDSP_Length(d))
                    for k in 0..<d { next[k] -= dot * previous[k] }
                }
                var norm: Float = 0
                vDSP_svesq(next, 1, &norm, vDSP_Length(d))
                guard norm > 0 else { break }
                v = next.map { $0 / norm.squareRoot() }
            }
            components.append(v)
            vDSP_mmul(centred, 1, v, 1, &scores, 1, vDSP_Length(n), 1, vDSP_Length(d))
            for i in 0..<n { projected[2 * i + c] = scores[i] }
        }
        var spread: Float = 0
        for i in 0..<n { spread += projected[2 * i] * projected[2 * i] / Float(n) }
        let scale = 1e-4 / max(spread.squareRoot(), .leastNormalMagnitude)
        return projected.map { $0 * scale }
    }

    /// x, y pairs moved and scaled into 0...1, keeping their shape.
    static func normalised(_ y: [Float]) -> [Float] {
        let xs = stride(from: 0, to: y.count, by: 2).map { y[$0] }
        let ys = stride(from: 1, to: y.count, by: 2).map { y[$0] }
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let span = max(maxX - minX, maxY - minY, .leastNormalMagnitude)
        let padX = (span - (maxX - minX)) / 2, padY = (span - (maxY - minY)) / 2
        return y.enumerated().map { k, value in
            k.isMultiple(of: 2) ? (value - minX + padX) / span : (value - minY + padY) / span
        }
    }
}
