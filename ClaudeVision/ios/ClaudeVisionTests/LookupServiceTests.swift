import XCTest
import CoreLocation
@testable import ClaudeVision

/// Specs for the lookup services' pure logic: barcode classification and the
/// prompt summaries each mode injects into Claude. Network paths are not
/// exercised here — the summaries are what the model actually sees, so their
/// shape is the contract.
final class LookupServiceTests: XCTestCase {

    // MARK: - BookLookupService.isISBN

    func testBooklandEAN13sAreISBNs() {
        XCTAssertTrue(BookLookupService.isISBN("9780141036144"))
        XCTAssertTrue(BookLookupService.isISBN("9791234567896"))
    }

    func testLegacyTenDigitISBNs() {
        XCTAssertTrue(BookLookupService.isISBN("0306406152"))
        XCTAssertTrue(BookLookupService.isISBN("030640615X"), "X check digit is valid in ISBN-10")
    }

    func testNonBookBarcodesAreNotISBNs() {
        XCTAssertFalse(BookLookupService.isISBN("5000159484695"), "grocery EAN-13 is not Bookland")
        XCTAssertFalse(BookLookupService.isISBN("12345"))
        XCTAssertFalse(BookLookupService.isISBN(""))
    }

    // MARK: - OpenFoodFactsService.Product.promptSummary

    private func makeProduct(novaGroup: Int?) -> OpenFoodFactsService.Product {
        OpenFoodFactsService.Product(
            name: "Baked Beans", brands: "Heinz", quantity: "415g",
            nutriScoreGrade: "b", novaGroup: novaGroup,
            ingredientsText: "Beans, tomatoes, sugar, salt",
            additiveTags: ["en:e250", "en:e330"], allergens: "en:gluten",
            energyKcal100g: 79, salt100g: 0.6, saturatedFat100g: 0.1,
            sugars100g: 4.7, fat100g: 0.2, proteins100g: 4.7, fiber100g: 4.1
        )
    }

    func testFoodSummaryContainsHealthSignals() {
        let summary = makeProduct(novaGroup: 4).promptSummary
        XCTAssertTrue(summary.contains("Baked Beans"))
        XCTAssertTrue(summary.contains("by Heinz"))
        XCTAssertTrue(summary.contains("Nutri-Score: B"))
        XCTAssertTrue(summary.contains("NOVA group: 4 (ultra-processed food)"))
        XCTAssertTrue(summary.contains("salt 0.6g"))
        XCTAssertTrue(summary.contains("E250, E330"), "additive tags are cleaned for the prompt")
        XCTAssertTrue(summary.contains("Allergens: gluten"))
    }

    func testNonUPFDoesNotGetTheUltraProcessedLabel() {
        let summary = makeProduct(novaGroup: 1).promptSummary
        XCTAssertTrue(summary.contains("NOVA group: 1"))
        XCTAssertFalse(summary.contains("ultra-processed"))
    }

    // MARK: - VehicleCheckService.Vehicle.promptSummary

    func testVehicleSummaryLeadsWithTaxAndMOT() {
        let vehicle = VehicleCheckService.Vehicle(
            registrationNumber: "AB12CDE",
            taxStatus: "Taxed", taxDueDate: "2026-11-01",
            motStatus: "Valid", motExpiryDate: "2026-09-14",
            make: "AUDI", colour: "BLUE", fuelType: "PETROL",
            engineCapacity: 1984, yearOfManufacture: 2018,
            co2Emissions: 152, markedForExport: false
        )
        let summary = vehicle.promptSummary
        XCTAssertTrue(summary.contains("DVLA record for AB12CDE"))
        XCTAssertTrue(summary.contains("Tax: Taxed (due 2026-11-01)"))
        XCTAssertTrue(summary.contains("MOT: Valid (expires 2026-09-14)"))
        XCTAssertTrue(summary.contains("BLUE, AUDI, petrol, registered 2018, 1984cc"))
        XCTAssertFalse(summary.contains("marked for export"))
    }

    func testVehicleSummaryHandlesMissingFieldsAndExportFlag() {
        let vehicle = VehicleCheckService.Vehicle(
            registrationNumber: "AB12CDE",
            taxStatus: nil, taxDueDate: nil, motStatus: nil, motExpiryDate: nil,
            make: nil, colour: nil, fuelType: nil, engineCapacity: nil,
            yearOfManufacture: nil, co2Emissions: nil, markedForExport: true
        )
        let summary = vehicle.promptSummary
        XCTAssertTrue(summary.contains("Tax: unknown"))
        XCTAssertTrue(summary.contains("MOT: unknown"))
        XCTAssertFalse(summary.contains("Vehicle:"), "no vehicle line when nothing is known")
        XCTAssertTrue(summary.contains("marked for export"))
    }

    func testDVLAResponseDecodes() throws {
        // Shape of a real VES 200 response
        let json = """
        {"registrationNumber":"AB12CDE","taxStatus":"Untaxed","taxDueDate":"2025-03-01",
         "motStatus":"Valid","motExpiryDate":"2026-09-14","make":"FORD","colour":"RED",
         "fuelType":"DIESEL","engineCapacity":1995,"yearOfManufacture":2016,"co2Emissions":120}
        """.data(using: .utf8)!
        let vehicle = try JSONDecoder().decode(VehicleCheckService.Vehicle.self, from: json)
        XCTAssertEqual(vehicle.registrationNumber, "AB12CDE")
        XCTAssertEqual(vehicle.taxStatus, "Untaxed")
        XCTAssertNil(vehicle.markedForExport, "absent optional fields decode as nil, not an error")
    }

    // MARK: - VenueFinderService.promptSummary

    func testVenueSummaryRanksAndDescribesEachVenue() {
        let venues = [
            VenueFinderService.Venue(
                name: "The Marksman", address: "254 Hackney Rd",
                latitude: 51.53, longitude: -0.07, category: "Pub",
                googleRating: 4.5, googleReviewCount: 3000, priceLevel: "$$",
                openNow: true, walkMinutes: 7,
                tripAdvisorRating: 4.5, tripAdvisorReviewCount: 812,
                tripAdvisorRanking: "#12 of 340 Restaurants in Hackney"
            ),
            VenueFinderService.Venue(
                name: "Corner Café", address: nil,
                latitude: 51.53, longitude: -0.07, category: nil,
                googleRating: nil, googleReviewCount: nil, priceLevel: nil,
                openNow: nil, walkMinutes: 3,
                tripAdvisorRating: nil, tripAdvisorReviewCount: nil,
                tripAdvisorRanking: nil
            ),
        ]
        let summary = VenueFinderService.promptSummary(venues)
        XCTAssertTrue(summary.contains("1. The Marksman"))
        XCTAssertTrue(summary.contains("Google 4.5★ from 3000 reviews"))
        XCTAssertTrue(summary.contains("TripAdvisor 4.5★ from 812 reviews"))
        XCTAssertTrue(summary.contains("#12 of 340 Restaurants in Hackney"))
        XCTAssertTrue(summary.contains("~7 min walk"))
        XCTAssertTrue(summary.contains("2. Corner Café"))
        XCTAssertTrue(summary.contains("hours unknown"), "unknown hours are flagged, not hidden")
    }

    // MARK: - HistoricalSitesService.promptSummary

    func testHistorySummaryGroundsNarrationInRetrievedText() {
        let sites = [
            HistoricalSitesService.Site(
                title: "St Mary's Church", distanceMeters: 120,
                description: "Church in Hertfordshire",
                extract: "St Mary's is a Grade I listed parish church dating from the 12th century.",
                url: "https://en.wikipedia.org/wiki/St_Mary's_Church"
            )
        ]
        let summary = HistoricalSitesService.promptSummary(sites)
        XCTAssertTrue(summary.contains("1. St Mary's Church — 120 m — Church in Hertfordshire"))
        XCTAssertTrue(summary.contains("Grade I listed parish church"))
        XCTAssertTrue(summary.contains("Source: https://en.wikipedia.org/wiki/St_Mary's_Church"))
    }

    func testHistorySummaryWithNoSitesForbidsInvention() {
        let summary = HistoricalSitesService.promptSummary([])
        XCTAssertTrue(summary.contains("no Wikipedia entries found"))
        XCTAssertTrue(summary.contains("do not invent local history"))
    }

    // MARK: - PlantNetService.IdentificationResult.promptSummary

    func testPlantSummaryListsTopThreeCandidatesWithConfidence() {
        let candidates = (1...4).map { i in
            PlantNetService.Identification(
                scientificName: "Species \(i)", commonNames: i == 1 ? ["English oak", "Common oak"] : [],
                genus: "Quercus", family: "Fagaceae", score: Double(5 - i) * 0.2
            )
        }
        let result = PlantNetService.IdentificationResult(
            bestMatch: "Quercus robur", candidates: candidates, remainingRequests: 480
        )
        let summary = result.promptSummary
        XCTAssertTrue(summary.contains("best match: Quercus robur"))
        XCTAssertTrue(summary.contains("1. Species 1 (80% confidence, family Fagaceae) — common names: English oak, Common oak"))
        XCTAssertTrue(summary.contains("3. Species 3"))
        XCTAssertFalse(summary.contains("4. Species 4"), "only the top 3 candidates go in the prompt")
    }

    // MARK: - BookLookupService.Book.promptSummary

    func testBookSummaryIncludesUsedCopiesLink() {
        let book = BookLookupService.Book(
            isbn: "9780141036144", title: "Nineteen Eighty-Four",
            authors: ["George Orwell"], publishedDate: "2008-07-03",
            pageCount: 336, description: "A dystopian classic.",
            categories: ["Fiction", "Classics"], averageRating: 4.5, ratingsCount: 1200
        )
        let summary = book.promptSummary
        XCTAssertTrue(summary.contains("\"Nineteen Eighty-Four\" by George Orwell (2008-07-03)"))
        XCTAssertTrue(summary.contains("336 pages"))
        XCTAssertTrue(summary.contains("Google Books rating: 4.5/5 from 1200 ratings"))
        XCTAssertTrue(summary.contains("https://www.worldofbooks.com/en-gb/search?q=9780141036144"))
    }
}
