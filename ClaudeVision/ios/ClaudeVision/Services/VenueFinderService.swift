import Foundation
import CoreLocation

/// Finds top-rated restaurants, bars, and cafés near a location for Trip mode.
/// Google Places (New) is the backbone; TripAdvisor enriches the top candidates
/// when a key is configured, and its failures never break the flow.
final class VenueFinderService {

    struct Venue {
        let name: String
        let address: String?
        let latitude: Double
        let longitude: Double
        let category: String?
        let googleRating: Double?
        let googleReviewCount: Int?
        let priceLevel: String?     // "$"–"$$$$"
        let openNow: Bool?
        let walkMinutes: Int
        var tripAdvisorRating: Double?
        var tripAdvisorReviewCount: Int?
        var tripAdvisorRanking: String?  // e.g. "#12 of 340 Restaurants in Shoreditch"
    }

    enum VenueError: LocalizedError {
        case missingAPIKey
        case apiError(statusCode: Int, message: String)
        case invalidResponse
        case noResults

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "No Google Places API key configured. Add one in Settings."
            case .apiError(let code, let message): return "Places API error (\(code)): \(message)"
            case .invalidResponse: return "Unexpected response from Places API"
            case .noResults: return "No venues found nearby"
            }
        }
    }

    // MARK: - Google Places (New) response models

    private struct PlacesResponse: Decodable {
        let places: [Place]?
    }

    private struct Place: Decodable {
        let displayName: LocalizedText?
        let formattedAddress: String?
        let location: LatLng?
        let rating: Double?
        let userRatingCount: Int?
        let priceLevel: String?
        let primaryTypeDisplayName: LocalizedText?
        let currentOpeningHours: OpeningHours?
    }

    private struct LocalizedText: Decodable { let text: String? }
    private struct LatLng: Decodable { let latitude: Double?; let longitude: Double? }
    private struct OpeningHours: Decodable { let openNow: Bool? }

    // MARK: - TripAdvisor response models

    private struct TANearbyResponse: Decodable {
        let data: [TANearbyItem]?
    }
    private struct TANearbyItem: Decodable {
        let locationId: String?
        let name: String?
        enum CodingKeys: String, CodingKey {
            case locationId = "location_id"
            case name
        }
    }
    private struct TADetails: Decodable {
        let rating: String?
        let numReviews: String?
        let rankingData: TARanking?
        enum CodingKeys: String, CodingKey {
            case rating
            case numReviews = "num_reviews"
            case rankingData = "ranking_data"
        }
    }
    private struct TARanking: Decodable {
        let rankingString: String?
        enum CodingKeys: String, CodingKey {
            case rankingString = "ranking_string"
        }
    }

    // MARK: - Search

    /// Searches restaurants/bars/cafés around the coordinate, ranks by
    /// rating weighted by review volume, filters out closed venues, and
    /// estimates walking time from straight-line distance.
    func findVenues(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double = 1500,
        googleKey: String,
        tripAdvisorKey: String
    ) async throws -> [Venue] {
        let key = googleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw VenueError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchNearby")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.displayName,places.formattedAddress,places.location,places.rating,places.userRatingCount,places.priceLevel,places.primaryTypeDisplayName,places.currentOpeningHours.openNow",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        let body: [String: Any] = [
            "includedTypes": ["restaurant", "bar", "cafe"],
            "maxResultCount": 20,
            "rankPreference": "POPULARITY",
            "locationRestriction": [
                "circle": [
                    "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                    "radius": radiusMeters
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VenueError.invalidResponse }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "unknown"
            throw VenueError.apiError(statusCode: http.statusCode, message: String(message.prefix(300)))
        }

        let decoded = try JSONDecoder().decode(PlacesResponse.self, from: data)
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var venues: [Venue] = (decoded.places ?? []).compactMap { place in
            guard let name = place.displayName?.text,
                  let lat = place.location?.latitude,
                  let lng = place.location?.longitude else { return nil }
            let meters = origin.distance(from: CLLocation(latitude: lat, longitude: lng))
            return Venue(
                name: name,
                address: place.formattedAddress,
                latitude: lat,
                longitude: lng,
                category: place.primaryTypeDisplayName?.text,
                googleRating: place.rating,
                googleReviewCount: place.userRatingCount,
                priceLevel: Self.priceSymbol(place.priceLevel),
                openNow: place.currentOpeningHours?.openNow,
                walkMinutes: Self.walkMinutes(straightLineMeters: meters)
            )
        }

        // Closed venues are the #1 real-world recommendation failure — drop them
        // (venues with unknown hours are kept).
        venues.removeAll { $0.openNow == false }
        guard !venues.isEmpty else { throw VenueError.noResults }

        // Rating weighted by review volume: a 4.5 from 3,000 beats a 4.8 from 12
        venues.sort { Self.score($0) > Self.score($1) }
        venues = Array(venues.prefix(10))

        // Optional TripAdvisor enrichment on the top candidates
        let taKey = tripAdvisorKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !taKey.isEmpty {
            await enrichWithTripAdvisor(&venues, near: coordinate, radiusMeters: radiusMeters, key: taKey)
        }

        return venues
    }

    private static func score(_ venue: Venue) -> Double {
        let rating = venue.googleRating ?? 0
        let count = Double(venue.googleReviewCount ?? 0)
        return rating * log10(count + 1)
    }

    private static func walkMinutes(straightLineMeters: Double) -> Int {
        // ~80 m/min walking pace, 1.3× winding factor for real streets
        max(1, Int((straightLineMeters * 1.3 / 80).rounded(.up)))
    }

    private static func priceSymbol(_ level: String?) -> String? {
        switch level {
        case "PRICE_LEVEL_INEXPENSIVE": return "$"
        case "PRICE_LEVEL_MODERATE": return "$$"
        case "PRICE_LEVEL_EXPENSIVE": return "$$$"
        case "PRICE_LEVEL_VERY_EXPENSIVE": return "$$$$"
        default: return nil
        }
    }

    // MARK: - TripAdvisor enrichment

    private func enrichWithTripAdvisor(
        _ venues: inout [Venue],
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        key: String
    ) async {
        var components = URLComponents(string: "https://api.content.tripadvisor.com/api/v1/location/nearby_search")!
        components.queryItems = [
            URLQueryItem(name: "latLong", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "category", value: "restaurants"),
            URLQueryItem(name: "radius", value: String(Int(radiusMeters))),
            URLQueryItem(name: "radiusUnit", value: "m"),
            URLQueryItem(name: "language", value: "en")
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let nearby = try? JSONDecoder().decode(TANearbyResponse.self, from: data),
              let items = nearby.data else { return }

        // Match by normalized name (IDs don't align across the two sources)
        for index in venues.indices.prefix(6) {
            let target = Self.normalized(venues[index].name)
            guard let match = items.first(where: {
                guard let name = $0.name else { return false }
                let candidate = Self.normalized(name)
                return candidate == target || candidate.contains(target) || target.contains(candidate)
            }), let locationId = match.locationId else { continue }

            var detailComponents = URLComponents(string: "https://api.content.tripadvisor.com/api/v1/location/\(locationId)/details")!
            detailComponents.queryItems = [
                URLQueryItem(name: "key", value: key),
                URLQueryItem(name: "language", value: "en")
            ]
            guard let detailURL = detailComponents.url,
                  let (detailData, detailResponse) = try? await URLSession.shared.data(from: detailURL),
                  (detailResponse as? HTTPURLResponse)?.statusCode == 200,
                  let details = try? JSONDecoder().decode(TADetails.self, from: detailData) else { continue }

            venues[index].tripAdvisorRating = details.rating.flatMap(Double.init)
            venues[index].tripAdvisorReviewCount = details.numReviews.flatMap(Int.init)
            venues[index].tripAdvisorRanking = details.rankingData?.rankingString
        }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Prompt formatting

    static func promptSummary(_ venues: [Venue]) -> String {
        var lines = ["Nearby venues, ranked by rating weighted by review volume (walking times are estimates):"]
        for (index, v) in venues.enumerated() {
            var parts = ["\(index + 1). \(v.name)"]
            if let category = v.category { parts.append(category) }
            if let rating = v.googleRating {
                let count = v.googleReviewCount.map { " from \($0) reviews" } ?? ""
                parts.append("Google \(rating)★\(count)")
            }
            if let taRating = v.tripAdvisorRating {
                let count = v.tripAdvisorReviewCount.map { " from \($0) reviews" } ?? ""
                parts.append("TripAdvisor \(taRating)★\(count)")
            }
            if let ranking = v.tripAdvisorRanking { parts.append(ranking) }
            if let price = v.priceLevel { parts.append(price) }
            parts.append("~\(v.walkMinutes) min walk")
            if v.openNow == nil { parts.append("hours unknown") }
            lines.append(parts.joined(separator: " — "))
        }
        return lines.joined(separator: "\n")
    }
}
