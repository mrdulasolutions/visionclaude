import Foundation

/// Identifies plants from camera frames using the Pl@ntNet API (https://my.plantnet.org).
/// Free tier allows 500 identification requests/day with an API key.
struct PlantNetService {

    struct Identification {
        let scientificName: String
        let commonNames: [String]
        let genus: String
        let family: String
        let score: Double  // 0.0 – 1.0 confidence
    }

    struct IdentificationResult {
        let bestMatch: String
        let candidates: [Identification]
        let remainingRequests: Int?

        /// Compact summary suitable for injecting into a Claude prompt.
        var promptSummary: String {
            var lines = ["Pl@ntNet identification results (best match: \(bestMatch)):"]
            for (index, candidate) in candidates.prefix(3).enumerated() {
                let confidence = Int(candidate.score * 100)
                let common = candidate.commonNames.isEmpty
                    ? ""
                    : " — common names: \(candidate.commonNames.prefix(3).joined(separator: ", "))"
                lines.append("\(index + 1). \(candidate.scientificName) (\(confidence)% confidence, family \(candidate.family))\(common)")
            }
            return lines.joined(separator: "\n")
        }
    }

    enum PlantNetError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(statusCode: Int, message: String)
        case noResults

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Pl@ntNet API key configured. Add one in Settings."
            case .invalidResponse:
                return "Unexpected response from Pl@ntNet."
            case .apiError(let statusCode, let message):
                return "Pl@ntNet error (\(statusCode)): \(message)"
            case .noResults:
                return "Pl@ntNet couldn't identify a plant in this image."
            }
        }
    }

    // MARK: - API Response Models

    private struct APIResponse: Decodable {
        let bestMatch: String?
        let results: [APIResult]
        let remainingIdentificationRequests: Int?
    }

    private struct APIResult: Decodable {
        let score: Double
        let species: APISpecies
    }

    private struct APISpecies: Decodable {
        let scientificNameWithoutAuthor: String
        let genus: APITaxon?
        let family: APITaxon?
        let commonNames: [String]?
    }

    private struct APITaxon: Decodable {
        let scientificNameWithoutAuthor: String
    }

    private struct APIErrorBody: Decodable {
        let message: String?
    }

    // MARK: - Identify

    /// Identifies the plant in a JPEG frame. `organ` hints what part of the plant
    /// is in frame ("auto", "leaf", "flower", "fruit", "bark").
    func identify(imageData: Data, apiKey: String, organ: String = "auto") async throws -> IdentificationResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw PlantNetError.missingAPIKey }

        var components = URLComponents(string: "https://my-api.plantnet.org/v2/identify/all")!
        components.queryItems = [URLQueryItem(name: "api-key", value: trimmedKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"organs\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(organ)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"images\"; filename=\"frame.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlantNetError.invalidResponse }

        guard http.statusCode == 200 else {
            // 404 = no species matched; other codes are real errors (401 bad key, 429 quota)
            if http.statusCode == 404 { throw PlantNetError.noResults }
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.message
                ?? String(data: data, encoding: .utf8) ?? "unknown"
            throw PlantNetError.apiError(statusCode: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        guard !decoded.results.isEmpty else { throw PlantNetError.noResults }

        let candidates = decoded.results.map { result in
            Identification(
                scientificName: result.species.scientificNameWithoutAuthor,
                commonNames: result.species.commonNames ?? [],
                genus: result.species.genus?.scientificNameWithoutAuthor ?? "",
                family: result.species.family?.scientificNameWithoutAuthor ?? "",
                score: result.score
            )
        }

        return IdentificationResult(
            bestMatch: decoded.bestMatch ?? candidates[0].scientificName,
            candidates: candidates,
            remainingRequests: decoded.remainingIdentificationRequests
        )
    }
}
