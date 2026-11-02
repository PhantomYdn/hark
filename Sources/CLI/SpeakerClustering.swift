import Foundation

/// Clusters per-utterance voice embeddings into speakers (PRD §6.7b). Pure
/// arithmetic over unit vectors, so it is unit-tested without models.
///
/// Only utterances of at least `coreSeconds` take part in deciding the
/// speakers; shorter ones are too noisy to cluster and are assigned to the
/// nearest resulting voice afterwards. With an exact count (equal
/// `--min-speakers`/`--max-speakers`) the core utterances are k-means
/// clustered to it. Otherwise average-linkage agglomerative clustering runs
/// until the closest pair of clusters is farther apart than the threshold
/// (cosine distance), clusters holding less than `minShare` of the speech time
/// are absorbed into the nearest remaining voice (a stray cluster of one or
/// two odd utterances is far more common than a speaker that quiet), and the
/// count is clamped into the bounds by re-clustering with k-means at the
/// bound it crossed.
enum SpeakerClustering {
    /// Cluster index per embedding (0-based, in order of first appearance).
    /// `durations` are the utterance lengths in seconds (nil: all alike).
    static func cluster(
        _ embeddings: [[Float]], durations: [Double]? = nil,
        minSpeakers: Int?, maxSpeakers: Int?, threshold: Double,
        minShare: Double = DiarizationDefaults.minSpeakerShare,
        coreSeconds: Double = DiarizationDefaults.coreUtteranceSeconds
    ) -> [Int] {
        let unit = embeddings.map(normalize)
        guard unit.count > 1 else { return unit.map { _ in 0 } }
        let durations = durations ?? [Double](repeating: coreSeconds, count: unit.count)
        var core = (0..<unit.count).filter { durations[$0] >= coreSeconds }
        if core.count < 2 { core = Array(0..<unit.count) }
        let coreUnit = core.map { unit[$0] }
        let lower = max(1, minSpeakers ?? 1)
        let upper = max(lower, maxSpeakers ?? coreUnit.count)

        var assignment: [Int]
        if let minSpeakers, let maxSpeakers, minSpeakers == maxSpeakers {
            assignment = kMeans(coreUnit, k: min(minSpeakers, coreUnit.count))
        } else {
            assignment = agglomerative(coreUnit, threshold: Float(threshold))
            absorbSmallClusters(
                &assignment, unit: coreUnit, durations: core.map { durations[$0] },
                minShare: minShare, keepAtLeast: lower)
            let found = Set(assignment).count
            let target = min(max(found, lower), upper)
            if target != found { assignment = kMeans(coreUnit, k: min(target, coreUnit.count)) }
        }

        // Short utterances follow the nearest voice decided on the long ones.
        let centroids = self.centroids(of: coreUnit, assignment: assignment)
        var labels = [Int](repeating: 0, count: unit.count)
        for (position, index) in core.enumerated() { labels[index] = assignment[position] }
        let coreSet = Set(core)
        for index in 0..<unit.count where !coreSet.contains(index) {
            labels[index] = nearest(unit[index], in: centroids)
        }
        return renumberByFirstAppearance(labels)
    }

    /// Reassigns the members of every cluster holding less than `minShare` of
    /// the total duration to the nearest other cluster's centroid, smallest
    /// cluster first, never going below `keepAtLeast` clusters.
    static func absorbSmallClusters(
        _ assignment: inout [Int], unit: [[Float]], durations: [Double],
        minShare: Double, keepAtLeast: Int
    ) {
        let total = durations.reduce(0, +)
        guard total > 0, minShare > 0 else { return }
        while Set(assignment).count > max(1, keepAtLeast) {
            var share: [Int: Double] = [:]
            for (cluster, duration) in zip(assignment, durations) { share[cluster, default: 0] += duration / total }
            guard let victim = share.filter({ $0.value < minShare }).min(by: { $0.value < $1.value })?.key
            else { return }
            let others = centroids(of: unit, assignment: assignment).filter { $0.key != victim }
            for index in assignment.indices where assignment[index] == victim {
                assignment[index] = nearest(unit[index], in: others)
            }
        }
    }

    /// Unit-length centroid per cluster id.
    static func centroids(of unit: [[Float]], assignment: [Int]) -> [Int: [Float]] {
        guard let dimension = unit.first?.count else { return [:] }
        var sums: [Int: [Float]] = [:]
        for (vector, cluster) in zip(unit, assignment) {
            var sum = sums[cluster] ?? [Float](repeating: 0, count: dimension)
            for d in 0..<dimension { sum[d] += vector[d] }
            sums[cluster] = sum
        }
        return sums.mapValues(normalize)
    }

    /// The id of the centroid closest (cosine) to `vector`; 0 when there is none.
    static func nearest(_ vector: [Float], in centroids: [Int: [Float]]) -> Int {
        centroids.min { cosineDistance(vector, $0.value) < cosineDistance(vector, $1.value) }?.key ?? 0
    }

    /// Renumbers cluster ids so the first embedding is cluster 0, the next new
    /// cluster 1, and so on.
    static func renumberByFirstAppearance(_ assignment: [Int]) -> [Int] {
        var numbers: [Int: Int] = [:]
        return assignment.map { id in
            if let number = numbers[id] { return number }
            numbers[id] = numbers.count
            return numbers.count - 1
        }
    }

    // MARK: Agglomerative (average linkage)

    /// Average-linkage agglomerative clustering, merging while the closest pair
    /// of clusters is under `threshold` (cosine distance). Each cluster caches
    /// its nearest neighbour, so a merge costs O(n) and the whole run O(n²).
    static func agglomerative(_ unit: [[Float]], threshold: Float) -> [Int] {
        let n = unit.count
        guard n > 1 else { return unit.map { _ in 0 } }
        var distance = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = cosineDistance(unit[i], unit[j])
                distance[i * n + j] = d
                distance[j * n + i] = d
            }
        }
        var size = [Int](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var nearest = [Int](repeating: -1, count: n)
        var nearestDistance = [Float](repeating: .infinity, count: n)
        // Union-find over merged clusters: a merged-away cluster points at the
        // one that absorbed it.
        var parent = Array(0..<n)
        func root(of i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }

        func refresh(_ i: Int) {
            nearest[i] = -1
            nearestDistance[i] = .infinity
            for j in 0..<n where j != i && active[j] {
                let d = distance[i * n + j]
                if d < nearestDistance[i] {
                    nearestDistance[i] = d
                    nearest[i] = j
                }
            }
        }
        for i in 0..<n { refresh(i) }

        var remaining = n
        while remaining > 1 {
            var a = -1
            var best: Float = .infinity
            for i in 0..<n where active[i] && nearestDistance[i] < best {
                best = nearestDistance[i]
                a = i
            }
            guard a >= 0, best < threshold else { break }
            let b = nearest[a]
            // Lance–Williams update for average linkage: the merged cluster's
            // distance to k is the size-weighted mean of a's and b's.
            let sa = Float(size[a])
            let sb = Float(size[b])
            for k in 0..<n where active[k] && k != a && k != b {
                let d = (sa * distance[a * n + k] + sb * distance[b * n + k]) / (sa + sb)
                distance[a * n + k] = d
                distance[k * n + a] = d
            }
            size[a] += size[b]
            active[b] = false
            remaining -= 1
            parent[b] = a
            refresh(a)
            for k in 0..<n where active[k] && k != a {
                if nearest[k] == a || nearest[k] == b {
                    refresh(k)
                } else if distance[k * n + a] < nearestDistance[k] {
                    nearestDistance[k] = distance[k * n + a]
                    nearest[k] = a
                }
            }
        }
        return (0..<n).map { root(of: $0) }
    }

    // MARK: k-means

    /// Spherical k-means with k-means++ seeding, run from `restarts` deterministic
    /// seeds and keeping the partition with the least inertia, so the same input
    /// always yields the same clusters.
    static func kMeans(_ unit: [[Float]], k: Int, restarts: Int = 10, iterations: Int = 100) -> [Int] {
        let n = unit.count
        guard k > 1, n > k else { return unit.map { _ in 0 } }
        var bestAssignment = [Int](repeating: 0, count: n)
        var bestInertia: Float = .infinity
        for seed in 0..<restarts {
            var rng = LinearCongruential(seed: UInt64(seed))
            var centroids = seedCentroids(unit, k: k, rng: &rng)
            var assignment = [Int](repeating: 0, count: n)
            for _ in 0..<iterations {
                var changed = false
                for (i, vector) in unit.enumerated() {
                    let nearest = closest(vector, to: centroids)
                    if assignment[i] != nearest {
                        assignment[i] = nearest
                        changed = true
                    }
                }
                centroids = recenter(unit, assignment: assignment, k: k, previous: centroids)
                if !changed { break }
            }
            let inertia = zip(unit, assignment).reduce(Float(0)) { sum, pair in
                sum + cosineDistance(pair.0, centroids[pair.1])
            }
            if inertia < bestInertia {
                bestInertia = inertia
                bestAssignment = assignment
            }
        }
        return bestAssignment
    }

    private static func seedCentroids(
        _ unit: [[Float]], k: Int, rng: inout LinearCongruential
    ) -> [[Float]] {
        var centroids = [unit[Int(rng.next() % UInt64(unit.count))]]
        while centroids.count < k {
            let weights = unit.map { vector in
                centroids.map { cosineDistance(vector, $0) }.min()!
            }
            let total = weights.reduce(0, +)
            guard total > 0 else {
                centroids.append(unit[centroids.count % unit.count])
                continue
            }
            var pick = Float(rng.next() % 1_000_000) / 1_000_000 * total
            var chosen = unit.count - 1
            for (i, weight) in weights.enumerated() {
                pick -= weight
                if pick <= 0 {
                    chosen = i
                    break
                }
            }
            centroids.append(unit[chosen])
        }
        return centroids
    }

    private static func recenter(
        _ unit: [[Float]], assignment: [Int], k: Int, previous: [[Float]]
    ) -> [[Float]] {
        let dimension = unit[0].count
        var sums = [[Float]](repeating: [Float](repeating: 0, count: dimension), count: k)
        var counts = [Int](repeating: 0, count: k)
        for (vector, cluster) in zip(unit, assignment) {
            counts[cluster] += 1
            for d in 0..<dimension { sums[cluster][d] += vector[d] }
        }
        return (0..<k).map { counts[$0] == 0 ? previous[$0] : normalize(sums[$0]) }
    }

    private static func closest(_ vector: [Float], to centroids: [[Float]]) -> Int {
        var best = 0
        var bestDistance: Float = .infinity
        for (i, centroid) in centroids.enumerated() {
            let d = cosineDistance(vector, centroid)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    // MARK: Vector helpers

    static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine distance in [0, 2]; 0 for parallel vectors.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 1 }
        return max(0, 1 - dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// A small deterministic generator, so clustering is reproducible.
    struct LinearCongruential {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 11
        }
    }
}
