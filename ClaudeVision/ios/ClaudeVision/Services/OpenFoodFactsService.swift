import Foundation
import Vision

/// Detects product barcodes (EAN/UPC) in a still frame using the Vision framework.
/// Used for Ray-Ban glasses frames, which don't go through the live
/// AVCaptureMetadataOutput pipeline that the iPhone camera has.
enum BarcodeDetector {
    static func detectProductBarcode(in imageData: Data) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.ean13, .ean8, .upce, .code128, .code39]
                let handler = VNImageRequestHandler(data: imageData)
                try? handler.perform([request])
                let payload = request.results?.compactMap { $0.payloadStringValue }.first
                continuation.resume(returning: payload)
            }
        }
    }
}

/// Looks up food products in Open Food Facts (https://openfoodfacts.org) —
/// a free, open database of 3M+ products. No API key required.
final class OpenFoodFactsService {

    struct Product {
        let name: String
        let brands: String?
        let quantity: String?
        let nutriScoreGrade: String?   // "a"–"e"
        let novaGroup: Int?            // 1–4; 4 = ultra-processed (UPF)
        let ingredientsText: String?
        let additiveTags: [String]     // e.g. "en:e250"
        let allergens: String?
        let energyKcal100g: Double?
        let salt100g: Double?
        let saturatedFat100g: Double?
        let sugars100g: Double?
        let fat100g: Double?
        let proteins100g: Double?
        let fiber100g: Double?

        /// Compact summary suitable for injecting into a Claude prompt.
        var promptSummary: String {
            let brandPart = (brands?.isEmpty == false) ? " by \(brands!)" : ""
            let quantityPart = (quantity?.isEmpty == false) ? " (\(quantity!))" : ""
            var lines = ["Open Food Facts data for \"\(name)\"\(brandPart)\(quantityPart):"]
            if let nutriScoreGrade {
                lines.append("Nutri-Score: \(nutriScoreGrade.uppercased())")
            }
            if let novaGroup {
                let upf = novaGroup == 4 ? " (ultra-processed food)" : ""
                lines.append("NOVA group: \(novaGroup)\(upf)")
            }
            var nutrition: [String] = []
            if let energyKcal100g { nutrition.append("energy \(Int(energyKcal100g)) kcal") }
            if let fat100g { nutrition.append("fat \(fat100g)g") }
            if let saturatedFat100g { nutrition.append("saturated fat \(saturatedFat100g)g") }
            if let sugars100g { nutrition.append("sugars \(sugars100g)g") }
            if let salt100g { nutrition.append("salt \(salt100g)g") }
            if let proteins100g { nutrition.append("protein \(proteins100g)g") }
            if let fiber100g { nutrition.append("fiber \(fiber100g)g") }
            if !nutrition.isEmpty {
                lines.append("Nutrition per 100g: \(nutrition.joined(separator: ", "))")
            }
            if !additiveTags.isEmpty {
                let additives = additiveTags.map { $0.replacingOccurrences(of: "en:", with: "").uppercased() }
                lines.append("Additives: \(additives.joined(separator: ", "))")
            }
            if let allergens, !allergens.isEmpty {
                lines.append("Allergens: \(allergens.replacingOccurrences(of: "en:", with: ""))")
            }
            if let ingredientsText, !ingredientsText.isEmpty {
                lines.append("Ingredients: \(ingredientsText.prefix(400))")
            }
            return lines.joined(separator: "\n")
        }
    }

    enum LookupError: LocalizedError {
        case notFound
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notFound: return "Product not in Open Food Facts"
            case .invalidResponse: return "Unexpected response from Open Food Facts"
            }
        }
    }

    // MARK: - API Response Models

    private struct APIResponse: Decodable {
        let status: Int
        let product: APIProduct?
    }

    private struct APIProduct: Decodable {
        let productName: String?
        let brands: String?
        let quantity: String?
        let nutriscoreGrade: String?
        let novaGroup: Int?
        let ingredientsText: String?
        let additivesTags: [String]?
        let allergens: String?
        let nutriments: APINutriments?

        enum CodingKeys: String, CodingKey {
            case productName = "product_name"
            case brands, quantity, allergens, nutriments
            case nutriscoreGrade = "nutriscore_grade"
            case novaGroup = "nova_group"
            case ingredientsText = "ingredients_text"
            case additivesTags = "additives_tags"
        }
    }

    private struct APINutriments: Decodable {
        let energyKcal: Double?
        let salt: Double?
        let saturatedFat: Double?
        let sugars: Double?
        let fat: Double?
        let proteins: Double?
        let fiber: Double?

        enum CodingKeys: String, CodingKey {
            case energyKcal = "energy-kcal_100g"
            case salt = "salt_100g"
            case saturatedFat = "saturated-fat_100g"
            case sugars = "sugars_100g"
            case fat = "fat_100g"
            case proteins = "proteins_100g"
            case fiber = "fiber_100g"
        }
    }

    // Product data barely changes and people re-scan the same items — cache hits are free.
    private var cache: [String: Product] = [:]

    // MARK: - Lookup

    func fetchProduct(barcode: String) async throws -> Product {
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cache[code] { return cached }

        let fields = "product_name,brands,quantity,nutriscore_grade,nova_group,ingredients_text,additives_tags,allergens,nutriments"
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json")!
        components.queryItems = [URLQueryItem(name: "fields", value: fields)]
        var request = URLRequest(url: components.url!)
        // OFF asks API users to identify themselves via User-Agent
        request.setValue("ClaudeVision/1.0 (iOS vision assistant)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LookupError.invalidResponse }
        if http.statusCode == 404 { throw LookupError.notFound }
        guard http.statusCode == 200 else { throw LookupError.invalidResponse }

        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        guard decoded.status == 1, let p = decoded.product else { throw LookupError.notFound }

        let product = Product(
            name: p.productName ?? "Unknown product",
            brands: p.brands,
            quantity: p.quantity,
            nutriScoreGrade: p.nutriscoreGrade,
            novaGroup: p.novaGroup,
            ingredientsText: p.ingredientsText,
            additiveTags: p.additivesTags ?? [],
            allergens: p.allergens,
            energyKcal100g: p.nutriments?.energyKcal,
            salt100g: p.nutriments?.salt,
            saturatedFat100g: p.nutriments?.saturatedFat,
            sugars100g: p.nutriments?.sugars,
            fat100g: p.nutriments?.fat,
            proteins100g: p.nutriments?.proteins,
            fiber100g: p.nutriments?.fiber
        )
        cache[code] = product
        return product
    }
}
