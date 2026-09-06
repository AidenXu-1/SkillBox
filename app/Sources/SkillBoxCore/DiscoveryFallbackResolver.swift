import Foundation

/// Media already supplies identities. Only unresolved identities go to the
/// next source; finding one identity must not hide another unresolved one.
public struct DiscoveryFallbackResolver: SkillDiscoveryProvider, Sendable {
    private let providers: [any SkillDiscoveryProvider]
    public init(providers: [any SkillDiscoveryProvider]) { self.providers = providers }

    public func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        let result = try await search(queries: [query], limitPerQuery: limit)
        return .init(candidates: result.candidates, hasMoreResults: !result.isExhaustive)
    }

    public func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        var seen = Set<String>()
        var remaining = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        var result = DiscoveryBatchSearchResult(candidates: [], originalQueryCandidateIDs: [])
        for provider in providers {
            try Task.checkCancellation()
            guard !remaining.isEmpty else { break }
            let batch: DiscoveryBatchSearchResult
            do {
                batch = try await DiscoverySearchCoordinator(providers: [provider], providerTimeout: .seconds(25))
                    .search(queries: remaining, limitPerQuery: limitPerQuery)
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch { result.failedSourceCount += 1; continue }
            result.candidates = DiscoverySearchCoordinator.mergeCandidates(existing: result.candidates, incoming: batch.candidates)
            result.originalQueryCandidateIDs.formUnion(batch.originalQueryCandidateIDs)
            result.failedSourceCount += batch.failedSourceCount
            result.failedQueryCount += batch.failedQueryCount
            result.saturatedQueryCount += batch.saturatedQueryCount
            result.failedCandidateVerificationCount += batch.failedCandidateVerificationCount
            result.deferredCandidateVerificationCount += batch.deferredCandidateVerificationCount
            result.rateLimitedUntil = [result.rateLimitedUntil, batch.rateLimitedUntil].compactMap { $0 }.max()
            remaining.removeAll { query in batch.candidates.contains { Self.matches(query, candidate: $0) } }
        }
        return result
    }

    private static func matches(_ query: String, candidate: DiscoveryCandidate) -> Bool {
        guard candidate.evidence.skillContentVerified else { return false }
        if query.lowercased().hasPrefix("repo:") {
            return String(query.dropFirst(5)).caseInsensitiveCompare(candidate.repositoryFullName) == .orderedSame
        }
        func normalize(_ text: String) -> String { text.lowercased().filter(\.isLetterOrNumber) }
        return normalize(query) == normalize(candidate.name)
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
