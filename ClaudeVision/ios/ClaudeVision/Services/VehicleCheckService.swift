import Foundation
import Vision

/// Reads UK number plates from a frame using on-device Vision OCR (no cloud
/// ANPR dependency; the reader is isolated here so it can be swapped for
/// Plate Recognizer or a local model later).
enum PlateReader {

    /// Current-format UK VRN (2001–): two letters, two digits, three letters.
    static func isValidVRN(_ candidate: String) -> Bool {
        let chars = Array(candidate)
        guard chars.count == 7 else { return false }
        return chars.enumerated().allSatisfy { i, c in
            let wantsLetter = (i < 2 || i > 3)   // AA00AAA
            return wantsLetter ? (c.isLetter && c.isUppercase && c.isASCII)
                               : (c.isNumber && c.isASCII)
        }
    }

    /// Uppercases, strips spaces/hyphens, and maps common OCR confusions
    /// (O↔0, I↔1, B↔8, S↔5, Z↔2) — but only at positions where the current
    /// UK plate format demands a letter or a digit. Returns nil if the result
    /// still isn't a valid VRN.
    static func normalizeVRN(_ raw: String) -> String? {
        let stripped = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard stripped.count == 7 else { return nil }

        let digitToLetter: [Character: Character] = ["0": "O", "1": "I", "8": "B", "5": "S", "2": "Z"]
        let letterToDigit: [Character: Character] = ["O": "0", "I": "1", "B": "8", "S": "5", "Z": "2"]

        var chars = Array(stripped)
        for i in chars.indices {
            let wantsLetter = (i < 2 || i > 3)   // AA00AAA
            if wantsLetter, chars[i].isNumber, let mapped = digitToLetter[chars[i]] {
                chars[i] = mapped
            } else if !wantsLetter, chars[i].isLetter, let mapped = letterToDigit[chars[i]] {
                chars[i] = mapped
            }
        }
        let candidate = String(chars)
        return isValidVRN(candidate) ? candidate : nil
    }

    /// Extracts a VRN from free text (spoken or typed), e.g. "check plate AB12 CDE".
    /// Scans a de-spaced version of the text so "AB12 CDE" and "AB 12 CDE" both match.
    static func extractVRN(fromText text: String) -> String? {
        let condensed = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard condensed.count >= 7 else { return nil }
        let chars = Array(condensed)
        for start in 0...(chars.count - 7) {
            let window = String(chars[start..<start + 7])
            if isValidVRN(window) { return window }
        }
        return nil
    }

    /// OCRs the frame and returns the first candidate that normalises to a
    /// valid VRN. Considers the top 3 read candidates per text region, since
    /// the best read of an angled or glary plate is often the second guess.
    static func readPlate(in imageData: Data) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false   // plates aren't words
                let handler = VNImageRequestHandler(data: imageData)
                try? handler.perform([request])

                for observation in request.results ?? [] {
                    for candidate in observation.topCandidates(3) {
                        if let vrn = normalizeVRN(candidate.string) {
                            continuation.resume(returning: vrn)
                            return
                        }
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    /// VRNs are personal data — log this instead of the full plate.
    static func masked(_ vrn: String) -> String {
        vrn.count > 2 ? "\(vrn.prefix(2))•••••" : "•••"
    }
}

/// Queries the DVLA Vehicle Enquiry Service (VES) for a vehicle's tax and MOT
/// status. Free API key from the DVLA developer portal. The VRN travels in the
/// request body, never the URL — it's classed as personal data.
final class VehicleCheckService {

    struct Vehicle: Decodable {
        let registrationNumber: String
        let taxStatus: String?
        let taxDueDate: String?
        let motStatus: String?
        let motExpiryDate: String?
        let make: String?
        let colour: String?
        let fuelType: String?
        let engineCapacity: Int?
        let yearOfManufacture: Int?
        let co2Emissions: Int?
        let markedForExport: Bool?

        /// Compact summary suitable for injecting into a Claude prompt.
        var promptSummary: String {
            var lines = ["DVLA record for \(registrationNumber):"]
            lines.append("Tax: \(taxStatus ?? "unknown")\(taxDueDate.map { " (due \($0))" } ?? "")")
            lines.append("MOT: \(motStatus ?? "unknown")\(motExpiryDate.map { " (expires \($0))" } ?? "")")
            var vehicle: [String] = []
            if let colour { vehicle.append(colour) }
            if let make { vehicle.append(make) }
            if let fuelType { vehicle.append(fuelType.lowercased()) }
            if let yearOfManufacture { vehicle.append("registered \(yearOfManufacture)") }
            if let engineCapacity { vehicle.append("\(engineCapacity)cc") }
            if !vehicle.isEmpty { lines.append("Vehicle: \(vehicle.joined(separator: ", "))") }
            if markedForExport == true { lines.append("Note: marked for export") }
            return lines.joined(separator: "\n")
        }
    }

    enum LookupError: LocalizedError {
        case noAPIKey
        case invalidVRN          // 400
        case notFound            // 404
        case rateLimited         // 429
        case serviceUnavailable  // 5xx

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No DVLA API key configured"
            case .invalidVRN: return "DVLA rejected the registration format"
            case .notFound: return "No vehicle found for that registration"
            case .rateLimited: return "DVLA rate limit hit — try again in a moment"
            case .serviceUnavailable: return "DVLA service unavailable — try again later"
            }
        }
    }

    static let askMIDURL = URL(string: "https://www.askmid.com/")!

    private let endpoint = URL(string: "https://driver-vehicle-licensing.api.gov.uk/vehicle-enquiry/v1/vehicles")!
    private var cache: [String: Vehicle] = [:]

    func fetchVehicle(vrn: String, apiKey: String) async throws -> Vehicle {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LookupError.noAPIKey }
        if let cached = cache[vrn] { return cached }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["registrationNumber": vrn])

        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            let vehicle = try JSONDecoder().decode(Vehicle.self, from: data)
            cache[vrn] = vehicle
            return vehicle
        case 400: throw LookupError.invalidVRN
        case 404: throw LookupError.notFound
        case 429: throw LookupError.rateLimited
        default: throw LookupError.serviceUnavailable
        }
    }
}
