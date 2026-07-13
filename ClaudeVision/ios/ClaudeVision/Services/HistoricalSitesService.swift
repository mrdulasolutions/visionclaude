import Foundation
import CoreLocation

/// Finds historic sites near a coordinate using Wikipedia's GeoSearch, then
/// prefetches each candidate's REST summary so narration is grounded in
/// retrieved text rather than model memory. Both APIs are free and keyless
/// (Wikipedia asks for a descriptive User-Agent, which we set).
///
/// Wikidata SPARQL and regional enrichers (Historic England, NRHP) are
/// deliberately deferred — this service is the pluggable seam for them.
final class HistoricalSitesService {

    struct Site {
        let title: String
        let distanceMeters: Int
        let description: String?   // short descriptor, e.g. "Church in Hertfordshire"
        let extract: String?       // lead paragraph — the grounding text
        let url: String
    }

    enum SearchError: LocalizedError {
        case requestFailed
        var errorDescription: String? { "Wikipedia search unavailable — try again shortly" }
    }

    // Focused walking radius first; widen for sparse areas (spec §8).
    private static let nearRadius = 300      // metres
    private static let wideRadius = 3000
    private static let maxCandidates = 8

    private var cache: (location: CLLocation, sites: [Site], time: Date)?

    // MARK: - Wikipedia models

    private struct GeoSearchResponse: Decodable {
        struct Query: Decodable { let geosearch: [Hit] }
        struct Hit: Decodable {
            let title: String
            let dist: Double
        }
        let query: Query?
    }

    private struct PageSummary: Decodable {
        struct ContentURLs: Decodable {
            struct Desktop: Decodable { let page: String }
            let desktop: Desktop
        }
        let title: String
        let description: String?
        let extract: String?
        let contentUrls: ContentURLs?
        enum CodingKeys: String, CodingKey {
            case title, description, extract
            case contentUrls = "content_urls"
        }
    }

    // MARK: - Search

    /// Sites don't move: cached results stay valid until the user walks
    /// ~200 m or a day passes.
    func findSites(near location: CLLocation) async throws -> [Site] {
        if let cache,
           location.distance(from: cache.location) < 200,
           Date().timeIntervalSince(cache.time) < 86_400 {
            return cache.sites
        }

        var hits = try await geoSearch(location.coordinate, radius: Self.nearRadius)
        if hits.count < 5 {
            hits = try await geoSearch(location.coordinate, radius: Self.wideRadius)
        }
        let top = hits.sorted { $0.dist < $1.dist }.prefix(Self.maxCandidates)

        // Prefetch all summaries in parallel (spec §7) — one slow page
        // shouldn't stall the rest, so failures just drop that candidate.
        let sites = await withTaskGroup(of: Site?.self) { group in
            for hit in top {
                group.addTask { [self] in
                    guard let summary = await fetchSummary(title: hit.title) else { return nil }
                    return Site(
                        title: summary.title,
                        distanceMeters: Int(hit.dist.rounded()),
                        description: summary.description,
                        extract: summary.extract,
                        url: summary.contentUrls?.desktop.page
                            ?? "https://en.wikipedia.org/wiki/\(hit.title.replacingOccurrences(of: " ", with: "_"))"
                    )
                }
            }
            var collected: [Site] = []
            for await site in group {
                if let site { collected.append(site) }
            }
            return collected.sorted { $0.distanceMeters < $1.distanceMeters }
        }

        cache = (location, sites, Date())
        return sites
    }

    private func geoSearch(_ coordinate: CLLocationCoordinate2D, radius: Int) async throws -> [GeoSearchResponse.Hit] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "geosearch"),
            URLQueryItem(name: "gscoord", value: "\(coordinate.latitude)|\(coordinate.longitude)"),
            URLQueryItem(name: "gsradius", value: "\(radius)"),
            URLQueryItem(name: "gslimit", value: "20"),
            URLQueryItem(name: "format", value: "json")
        ]
        let data = try await fetch(components.url!)
        guard let decoded = try? JSONDecoder().decode(GeoSearchResponse.self, from: data) else {
            throw SearchError.requestFailed
        }
        return decoded.query?.geosearch ?? []
    }

    private func fetchSummary(title: String) async -> PageSummary? {
        guard let encoded = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
              let data = try? await fetch(url) else { return nil }
        return try? JSONDecoder().decode(PageSummary.self, from: data)
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("ClaudeVision/1.0 (iOS vision assistant)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SearchError.requestFailed
        }
        return data
    }

    // MARK: - Prompt summary

    /// Compact candidate list suitable for injecting into a Claude prompt.
    static func promptSummary(_ sites: [Site]) -> String {
        guard !sites.isEmpty else {
            return "Historic site search: no Wikipedia entries found within \(wideRadius / 1000) km of the user. Say so plainly — do not invent local history."
        }
        var lines = ["Nearby historic candidates from Wikipedia GeoSearch (sorted by distance from the user):"]
        for (i, site) in sites.enumerated() {
            var line = "\(i + 1). \(site.title) — \(site.distanceMeters) m"
            if let description = site.description, !description.isEmpty {
                line += " — \(description)"
            }
            lines.append(line)
            if let extract = site.extract, !extract.isEmpty {
                lines.append("   \(extract.prefix(350))")
            }
            lines.append("   Source: \(site.url)")
        }
        return lines.joined(separator: "\n")
    }
}
