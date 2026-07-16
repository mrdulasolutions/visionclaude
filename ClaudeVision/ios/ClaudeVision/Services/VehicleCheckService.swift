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

/// Checks a vehicle's tax and MOT status via the public gov.uk service behind
/// https://www.gov.uk/check-vehicle-tax (vehicleenquiry.service.gov.uk). No
/// API key needed: the service walks the same three-step wizard a person does
/// in Safari — start page, submit registration, confirm vehicle — and parses
/// the results HTML. One lookup per user question; the VRN travels in POST
/// bodies, never the URL — it's classed as personal data.
final class VehicleCheckService {

    struct Vehicle {
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
        case notFound            // wizard lands on /VehicleNotFound
        case rateLimited         // 429
        case serviceUnavailable  // non-200 anywhere in the flow
        case pageChanged         // 200 but the HTML no longer parses

        var errorDescription: String? {
            switch self {
            case .notFound: return "No vehicle found for that registration"
            case .rateLimited: return "gov.uk rate limit hit — try again in a moment"
            case .serviceUnavailable: return "gov.uk vehicle check unavailable — try again later"
            case .pageChanged: return "The gov.uk vehicle check page has changed and couldn't be read"
            }
        }
    }

    static let askMIDURL = URL(string: "https://www.askmid.com/")!

    private let startURL = URL(string: "https://vehicleenquiry.service.gov.uk/?locale=en")!
    private let saveURL = URL(string: "https://vehicleenquiry.service.gov.uk/vehicle-enquiry/save?locale=en")!
    private var cache: [String: Vehicle] = [:]

    // Ephemeral session so the wizard's cookies live here, not in the app's
    // shared jar. Re-fetching the start page each lookup resets the wizard.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": "en-GB,en;q=0.9",
        ]
        return URLSession(configuration: config)
    }()

    func fetchVehicle(vrn: String) async throws -> Vehicle {
        if let cached = cache[vrn] { return cached }

        // Step 1: start page — establishes the session cookie and CSRF token.
        let start = try await load(URLRequest(url: startURL))
        guard let startToken = Self.authenticityToken(in: start.html) else {
            throw LookupError.pageChanged
        }

        // Step 2: submit the registration. Redirects to /ConfirmVehicle on a
        // hit, /VehicleNotFound on a miss.
        let confirm = try await load(formPOST([
            ("authenticity_token", startToken),
            ("wizard_vehicle_enquiry_capture_vrn[vrn]", vrn),
        ]))
        if confirm.path.contains("VehicleNotFound") { throw LookupError.notFound }
        guard confirm.path.contains("ConfirmVehicle"),
              let confirmToken = Self.authenticityToken(in: confirm.html) else {
            throw LookupError.pageChanged
        }

        // Step 3: answer "Yes" to "Is this the vehicle?" — lands on the
        // /VehicleFound results page.
        let result = try await load(formPOST([
            ("authenticity_token", confirmToken),
            ("wizard_vehicle_enquiry_capture_confirm_vehicle[confirmed]", "Yes"),
        ]))
        guard result.path.contains("VehicleFound"),
              let vehicle = Self.parseVehicle(html: result.html, vrn: vrn) else {
            throw LookupError.pageChanged
        }
        cache[vrn] = vehicle
        return vehicle
    }

    // MARK: - HTTP plumbing

    private func load(_ request: URLRequest) async throws -> (html: String, path: String) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LookupError.serviceUnavailable }
        switch http.statusCode {
        case 200: break
        case 429: throw LookupError.rateLimited
        default: throw LookupError.serviceUnavailable
        }
        guard let html = String(data: data, encoding: .utf8) else { throw LookupError.pageChanged }
        return (html, http.url?.path ?? "")
    }

    private func formPOST(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: saveURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let body = fields.map { name, value in
            let n = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(n)=\(v)"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    // MARK: - HTML parsing (static so specs can exercise it directly)

    /// The Rails CSRF token from the enquiry form. Pages carry two — the
    /// cookie-banner form's first — so take the last match.
    static func authenticityToken(in html: String) -> String? {
        matches(#"name="authenticity_token" value="([^"]+)""#, in: html).last
    }

    /// The `<dd>` value of a `govuk-summary-list__row` by its id attribute.
    /// "Not available" collapses to nil.
    static func summaryValue(id: String, in html: String) -> String? {
        guard let raw = matches(#"id="\#(id)"[^>]*>.*?<dd>\s*([^<]*?)\s*</dd>"#, in: html).first,
              !raw.isEmpty, raw != "Not available" else { return nil }
        return raw
    }

    /// Builds a Vehicle from the /VehicleFound results page. Statuses come
    /// from the visually-hidden panel sentences ("Vehicle X is Taxed",
    /// "Vehicle X has a valid MOT certificate"); dates from the panel bodies.
    static func parseVehicle(html: String, vrn: String) -> Vehicle? {
        // Slice the two status panels; MOT panel follows the tax panel.
        guard let taxRange = html.range(of: #"id="tax-status-panel""#, options: .regularExpression),
              let motRange = html.range(of: #"id="mot-status-panel""#, options: .regularExpression),
              taxRange.upperBound <= motRange.lowerBound else { return nil }
        let taxPanel = String(html[taxRange.upperBound..<motRange.lowerBound])
        let motPanel = String(html[motRange.upperBound...])

        let taxStatus = matches(#"Vehicle\s+[A-Z0-9]+\s+is\s+([^<]+)"#, in: taxPanel).first
            ?? summaryValue(id: "vehicleStatus", in: html)
        let taxDueDate = matches(#"(?:Tax due|Expires):\s*([^<]+)"#, in: taxPanel).first

        // "has a valid MOT certificate" / "does not have a valid MOT" / no
        // details held — keep the raw phrase when it doesn't map cleanly, it
        // still reads fine in the prompt summary.
        var motStatus: String?
        if let phrase = matches(#"Vehicle\s+[A-Z0-9]+\s+([^<]+)"#, in: motPanel).first {
            if phrase.localizedCaseInsensitiveContains("not") {
                motStatus = "Not valid"
            } else if phrase.localizedCaseInsensitiveContains("valid MOT") {
                motStatus = "Valid"
            } else {
                motStatus = phrase
            }
        }
        let motExpiryDate = matches(#"Expires:\s*([^<]+)"#, in: motPanel).first

        return Vehicle(
            registrationNumber: vrn,
            taxStatus: taxStatus,
            taxDueDate: taxDueDate,
            motStatus: motStatus,
            motExpiryDate: motExpiryDate,
            make: summaryValue(id: "make", in: html),
            colour: summaryValue(id: "colour", in: html),
            fuelType: summaryValue(id: "fuel_type", in: html),
            engineCapacity: summaryValue(id: "engine_capacity", in: html).flatMap { Int($0.filter(\.isNumber)) },
            yearOfManufacture: summaryValue(id: "year_of_manufacture", in: html).flatMap { Int($0.filter(\.isNumber)) },
            co2Emissions: summaryValue(id: "co2_emissions", in: html).flatMap { Int($0.filter(\.isNumber)) },
            markedForExport: summaryValue(id: "marked_for_export", in: html).map { $0 == "Yes" }
        )
    }

    /// First capture group of every match, whitespace-collapsed and trimmed.
    private static func matches(_ pattern: String, in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: html) else { return nil }
            let value = html[r].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}
