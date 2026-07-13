import Foundation

/// Looks up books by ISBN using Google Books and Open Library in parallel.
/// Both APIs are free and keyless. Google Books contributes description and
/// a rating signal; Open Library contributes subjects and fills gaps.
final class BookLookupService {

    struct Book {
        let isbn: String
        var title: String
        var authors: [String]
        var publishedDate: String?
        var pageCount: Int?
        var description: String?
        var categories: [String]
        var averageRating: Double?   // Google Books, out of 5
        var ratingsCount: Int?

        /// Compact summary suitable for injecting into a Claude prompt.
        var promptSummary: String {
            var lines = ["Book lookup for ISBN \(isbn):"]
            let byline = authors.isEmpty ? "" : " by \(authors.joined(separator: ", "))"
            lines.append("\"\(title)\"\(byline)\(publishedDate.map { " (\($0))" } ?? "")")
            if let pageCount { lines.append("\(pageCount) pages") }
            if !categories.isEmpty { lines.append("Subjects: \(categories.prefix(6).joined(separator: ", "))") }
            if let averageRating {
                let count = ratingsCount.map { " from \($0) ratings" } ?? ""
                lines.append("Google Books rating: \(averageRating)/5\(count)")
            }
            if let description, !description.isEmpty {
                lines.append("Description: \(description.prefix(600))")
            }
            lines.append("Used copies: https://www.worldofbooks.com/en-gb/search?q=\(isbn)")
            return lines.joined(separator: "\n")
        }
    }

    enum LookupError: LocalizedError {
        case notFound
        var errorDescription: String? { "Book not found in Google Books or Open Library" }
    }

    /// ISBN barcodes are EAN-13s in the 978/979 "Bookland" prefix, or legacy 10-digit ISBNs.
    static func isISBN(_ code: String) -> Bool {
        let digits = code.filter { $0.isNumber || $0 == "X" }
        if digits.count == 13 { return digits.hasPrefix("978") || digits.hasPrefix("979") }
        return digits.count == 10
    }

    // MARK: - Google Books models

    private struct GBResponse: Decodable {
        let totalItems: Int?
        let items: [GBItem]?
    }
    private struct GBItem: Decodable { let volumeInfo: GBVolumeInfo? }
    private struct GBVolumeInfo: Decodable {
        let title: String?
        let authors: [String]?
        let publishedDate: String?
        let description: String?
        let pageCount: Int?
        let categories: [String]?
        let averageRating: Double?
        let ratingsCount: Int?
    }

    // MARK: - Open Library models (jscmd=data)

    private struct OLBook: Decodable {
        let title: String?
        let authors: [OLAuthor]?
        let publishDate: String?
        let numberOfPages: Int?
        let subjects: [OLSubject]?
        enum CodingKeys: String, CodingKey {
            case title, authors, subjects
            case publishDate = "publish_date"
            case numberOfPages = "number_of_pages"
        }
    }
    private struct OLAuthor: Decodable { let name: String? }
    private struct OLSubject: Decodable { let name: String? }

    private var cache: [String: Book] = [:]

    // MARK: - Lookup

    func fetchBook(isbn rawISBN: String) async throws -> Book {
        let isbn = rawISBN.filter { $0.isNumber || $0 == "X" }
        if let cached = cache[isbn] { return cached }

        async let googleResult = fetchGoogleBooks(isbn: isbn)
        async let openLibraryResult = fetchOpenLibrary(isbn: isbn)
        let (google, openLibrary) = await (googleResult, openLibraryResult)

        guard google != nil || openLibrary != nil else { throw LookupError.notFound }

        var book = Book(
            isbn: isbn,
            title: google?.title ?? openLibrary?.title ?? "Unknown title",
            authors: google?.authors ?? openLibrary?.authors?.compactMap(\.name) ?? [],
            publishedDate: google?.publishedDate ?? openLibrary?.publishDate,
            pageCount: google?.pageCount ?? openLibrary?.numberOfPages,
            description: google?.description,
            categories: google?.categories ?? [],
            averageRating: google?.averageRating,
            ratingsCount: google?.ratingsCount
        )
        // Open Library subjects are richer than Google's categories — merge them in
        if let subjects = openLibrary?.subjects?.compactMap(\.name), !subjects.isEmpty {
            let existing = Set(book.categories.map { $0.lowercased() })
            book.categories += subjects.filter { !existing.contains($0.lowercased()) }.prefix(5)
        }

        cache[isbn] = book
        return book
    }

    private func fetchGoogleBooks(isbn: String) async -> GBVolumeInfo? {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [URLQueryItem(name: "q", value: "isbn:\(isbn)")]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(GBResponse.self, from: data) else { return nil }
        return decoded.items?.first?.volumeInfo
    }

    private func fetchOpenLibrary(isbn: String) async -> OLBook? {
        var components = URLComponents(string: "https://openlibrary.org/api/books")!
        components.queryItems = [
            URLQueryItem(name: "bibkeys", value: "ISBN:\(isbn)"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "jscmd", value: "data")
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode([String: OLBook].self, from: data) else { return nil }
        return decoded["ISBN:\(isbn)"]
    }
}
