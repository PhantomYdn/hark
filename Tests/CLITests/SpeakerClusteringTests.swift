import Foundation
import Testing

@testable import CLI

/// Per-utterance voice clustering (PRD §6.7b). Synthetic unit vectors stand in
/// for embeddings: three well-separated directions with small jitter, so the
/// expected partition is known. No models, no audio.
@Suite("Speaker clustering")
struct SpeakerClusteringTests {
    /// `count` vectors near `axis` (a one-hot direction), jittered deterministically.
    private func voice(_ axis: Int, count: Int, dimension: Int = 8, jitter: Float = 0.2) -> [[Float]] {
        (0..<count).map { i in
            (0..<dimension).map { d in
                let base: Float = d == axis ? 1 : 0
                let wobble = Float((i * 7 + d * 13) % 11) / 11 - 0.5
                return base + jitter * wobble
            }
        }
    }

    /// Interleaves three voices the way turns alternate in a conversation.
    private var conversation: (vectors: [[Float]], truth: [Int]) {
        let a = voice(0, count: 6), b = voice(3, count: 5), c = voice(6, count: 4)
        var vectors: [[Float]] = []
        var truth: [Int] = []
        for i in 0..<6 {
            vectors.append(a[i]); truth.append(0)
            if i < 5 { vectors.append(b[i]); truth.append(1) }
            if i < 4 { vectors.append(c[i]); truth.append(2) }
        }
        return (vectors, truth)
    }

    @Test func exactCountRecoversThePartitionNumberedByFirstAppearance() {
        let (vectors, truth) = conversation
        let out = SpeakerClustering.cluster(vectors, minSpeakers: 3, maxSpeakers: 3, threshold: 0.8)
        #expect(out == truth)
        #expect(out[0] == 0)  // the first utterance is always Speaker 1
    }

    @Test func thresholdDecidesTheCountWhenUnbounded() {
        let (vectors, truth) = conversation
        // Orthogonal voices are 1.0 apart, same-voice jitter well under 0.5.
        let three = SpeakerClustering.cluster(vectors, minSpeakers: nil, maxSpeakers: nil, threshold: 0.5)
        #expect(three == truth)
        // A cut above every distance merges everything into one speaker.
        let one = SpeakerClustering.cluster(vectors, minSpeakers: nil, maxSpeakers: nil, threshold: 1.5)
        #expect(Set(one) == [0])
    }

    @Test func boundsClampTheAutomaticCount() {
        let (vectors, truth) = conversation
        // Too many at a tiny threshold: the cap re-clusters to 3.
        let capped = SpeakerClustering.cluster(vectors, minSpeakers: nil, maxSpeakers: 3, threshold: 0.01)
        #expect(Set(capped).count == 3)
        #expect(capped == truth)
        // Too few at a huge threshold: the floor re-clusters to 2.
        let floored = SpeakerClustering.cluster(vectors, minSpeakers: 2, maxSpeakers: nil, threshold: 1.5)
        #expect(Set(floored).count == 2)
    }

    @Test func degenerateInputsAreOneSpeaker() {
        #expect(SpeakerClustering.cluster([], minSpeakers: 3, maxSpeakers: 3, threshold: 0.8) == [])
        #expect(SpeakerClustering.cluster([[1, 0]], minSpeakers: nil, maxSpeakers: nil, threshold: 0.8) == [0])
        // Fewer utterances than the requested count: everyone is still labeled.
        let two = SpeakerClustering.cluster([[1, 0], [0, 1]], minSpeakers: 5, maxSpeakers: 5, threshold: 0.8)
        #expect(two.count == 2)
    }

    @Test func renumberingFollowsFirstAppearance() {
        #expect(SpeakerClustering.renumberByFirstAppearance([7, 7, 2, 7, 9, 2]) == [0, 0, 1, 0, 2, 1])
    }

    @Test func cosineDistanceIsZeroForParallelAndOneForOrthogonal() {
        #expect(abs(SpeakerClustering.cosineDistance([1, 1], [2, 2])) < 1e-6)
        #expect(abs(SpeakerClustering.cosineDistance([1, 0], [0, 1]) - 1) < 1e-6)
        #expect(SpeakerClustering.cosineDistance([0, 0], [1, 0]) == 1)
    }

    @Test func agglomerativeMatchesTheKnownPartitionOnEasyData() {
        let (vectors, truth) = conversation
        let unit = vectors.map(SpeakerClustering.normalize)
        let labels = SpeakerClustering.renumberByFirstAppearance(
            SpeakerClustering.agglomerative(unit, threshold: 0.5))
        #expect(labels == truth)
    }
}
