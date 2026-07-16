import Foundation
import WebKit

/// Price-compares a book across BookFinder.com and AddALL by ISBN.
///
/// Both sites gate plain HTTP behind bot protection (BookFinder: AWS WAF JS
/// challenge; AddALL: reCAPTCHA v3 token on every search), so URLSession is a
/// dead end. Instead each search runs in a hidden WKWebView: real WebKit
/// passes the WAF challenge and the page's own JS mints the reCAPTCHA token,
/// then an injected collector script walks the rendered DOM for offers.
/// Markup on both sites is old-school and shifts over time, so the collector
/// matches generically on currency-amount patterns per row rather than CSS
/// classes.
@MainActor
final class BookPriceService {

    struct Offer: Identifiable, Equatable {
        let id = UUID()
        let seller: String
        let price: Double
        let currencySymbol: String
        let url: URL
        let source: String   // "BookFinder" or "AddALL"

        var priceLabel: String { "\(currencySymbol)\(String(format: "%.2f", price))" }
    }

    private var pages: [ScraperPage] = []

    /// Searches both sites concurrently, then merges: duplicates (same seller
    /// at the same price, regardless of which site surfaced it) collapse to
    /// one entry, and the result is sorted cheapest first.
    func findOffers(isbn: String) async -> [Offer] {
        async let bookFinder = scrapeBookFinder(isbn: isbn)
        async let addAll = scrapeAddAll(isbn: isbn)
        let merged = await bookFinder + addAll

        var seen = Set<String>()
        var out: [Offer] = []
        for offer in merged.sorted(by: { $0.price < $1.price }) {
            let key = "\(offer.seller.lowercased())|\(String(format: "%.2f", offer.price))"
            if seen.insert(key).inserted { out.append(offer) }
        }
        return Array(out.prefix(20))
    }

    func cancel() {
        pages.forEach { $0.tearDown() }
        pages.removeAll()
    }

    // MARK: - BookFinder

    private func scrapeBookFinder(isbn: String) async -> [Offer] {
        guard let url = URL(string:
            "https://www.bookfinder.com/search/?isbn=\(isbn)&mode=isbn&st=sr&ac=qr&destination=gb&currency=GBP"
        ) else { return [] }

        let page = ScraperPage()
        pages.append(page)
        defer { page.tearDown(); pages.removeAll { $0 === page } }

        page.load(url)
        // The WAF interstitial solves itself and reloads to the results page;
        // poll until offer rows appear.
        let offers = await page.pollForOffers(attempts: 18, interval: 1.0)
        print("[BookPrice] BookFinder: \(offers.count) offers")
        return offers.map { raw in
            Offer(seller: raw.seller, price: raw.price, currencySymbol: raw.symbol,
                  url: raw.url, source: "BookFinder")
        }
    }

    // MARK: - AddALL

    private func scrapeAddAll(isbn: String) async -> [Offer] {
        guard let home = URL(string: "https://www.addall.com/") else { return [] }

        let page = ScraperPage()
        pages.append(page)
        defer { page.tearDown(); pages.removeAll { $0 === page } }

        page.load(home)

        // The homepage JS fills #g-recaptcha-response shortly after load;
        // submitting before that lands on "Bot activity detected".
        let submitJS = """
        (function(){
          var f = document.forms['newform'];
          if (!f) return 'noform';
          var t = document.getElementById('g-recaptcha-response');
          if (!t || !t.value) return 'notoken';
          f.elements['query'].value = '\(isbn)';
          f.elements['type'].value = 'ISBN';
          f.submit();
          return 'submitted';
        })()
        """
        var submitted = false
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let result = await page.evaluate(submitJS) as? String, result == "submitted" {
                submitted = true
                break
            }
        }
        guard submitted else {
            print("[BookPrice] AddALL: token never appeared — skipping")
            return []
        }

        let offers = await page.pollForOffers(attempts: 15, interval: 1.0)
        print("[BookPrice] AddALL: \(offers.count) offers")
        return offers.map { raw in
            Offer(seller: raw.seller, price: raw.price, currencySymbol: raw.symbol,
                  url: raw.url, source: "AddALL")
        }
    }
}

// MARK: - Hidden WKWebView wrapper

@MainActor
private final class ScraperPage: NSObject {

    struct RawOffer {
        let seller: String
        let price: Double
        let symbol: String
        let url: URL
    }

    private var webView: WKWebView?

    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent cookies: pass the WAF challenge once, not every scan
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        webView = view
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func tearDown() {
        webView?.stopLoading()
        webView = nil
    }

    /// The completion-handler API — the async overload of evaluateJavaScript
    /// traps when the script yields null/undefined, which the polling scripts
    /// routinely do mid-load.
    func evaluate(_ js: String) async -> Any? {
        await withCheckedContinuation { continuation in
            guard let webView else { return continuation.resume(returning: nil) }
            webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: result)
            }
        }
    }

    /// Walks every table row / list item in the rendered page and keeps rows
    /// that contain both a currency amount and an outbound link. Seller name
    /// falls back from anchor text to link hostname.
    private static let collectorJS = """
    (function(){
      var priceRe = /([£$€])\\s?([0-9]{1,4}(?:[.,][0-9]{2}))/;
      var out = [];
      var rows = document.querySelectorAll('tr, li, .item, .result');
      rows.forEach(function(r){
        if (r.querySelector('tr')) return;              // skip container rows of nested tables
        var text = (r.innerText || '').trim();
        if (!text) return;
        var m = priceRe.exec(text);
        if (!m) return;
        var best = null;
        r.querySelectorAll('a[href]').forEach(function(a){
          if (best) return;
          var h = a.href || '';
          if (h.indexOf('http') !== 0) return;
          if (h.indexOf('javascript') === 0) return;
          best = a;
        });
        if (!best) return;
        var seller = (best.innerText || '').trim();
        if (!seller || priceRe.test(seller) || seller.length > 50) {
          try { seller = new URL(best.href).hostname.replace('www.',''); } catch(e) { seller = ''; }
        }
        if (!seller) return;
        out.push({ s: seller, y: m[1], p: parseFloat(m[2].replace(',','.')), u: best.href });
      });
      return JSON.stringify(out);
    })()
    """

    func pollForOffers(attempts: Int, interval: TimeInterval) async -> [RawOffer] {
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let json = await evaluate(Self.collectorJS) as? String,
                  let data = json.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !items.isEmpty else { continue }

            let offers: [RawOffer] = items.compactMap { item in
                guard let seller = item["s"] as? String,
                      let symbol = item["y"] as? String,
                      let price = item["p"] as? Double,
                      price > 0, price < 10_000,
                      let urlString = item["u"] as? String,
                      let url = URL(string: urlString) else { return nil }
                return RawOffer(
                    seller: seller.trimmingCharacters(in: .whitespacesAndNewlines),
                    price: price, symbol: symbol, url: url
                )
            }
            if !offers.isEmpty { return offers }
        }
        return []
    }
}
