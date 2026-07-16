import SwiftUI

/// Results sheet for the "scan book" price comparison: offers sorted
/// cheapest-first, each row opening the seller page in the browser.
struct BookOffersView: View {
    let bookTitle: String
    let offers: [BookPriceService.Offer]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if offers.isEmpty {
                    ContentUnavailableView(
                        "No offers found",
                        systemImage: "books.vertical",
                        description: Text("Neither BookFinder nor AddALL returned prices for this ISBN.")
                    )
                } else {
                    List {
                        ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
                            Link(destination: offer.url) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            if index == 0 {
                                                Text("CHEAPEST")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.2))
                                                    .foregroundStyle(.green)
                                                    .clipShape(Capsule())
                                            }
                                            Text(offer.seller)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                        }
                                        Text("via \(offer.source)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(offer.priceLabel)
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(index == 0 ? .green : .primary)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(bookTitle.isEmpty ? "Book Prices" : bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
