import SwiftUI

struct TranscriptView: View {
    let messages: [TranscriptMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(.black.opacity(0.3))
        .cornerRadius(16)
    }
}

struct MessageBubble: View {
    let message: TranscriptMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Role label
                Text(isUser ? "You" : "Claude")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isUser ? .blue : .orange)
                    .textCase(.uppercase)

                // Message text
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .multilineTextAlignment(isUser ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Tool call badges
                if !message.toolCalls.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 8))
                            .foregroundColor(.purple)
                        ForEach(message.toolCalls.prefix(2), id: \.name) { tool in
                            Text(tool.name)
                                .font(.system(size: 9))
                                .foregroundColor(.purple)
                        }
                        if message.toolCalls.count > 2 {
                            Text("+\(message.toolCalls.count - 2)")
                                .font(.system(size: 9))
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isUser ? Color.blue.opacity(0.25) : Color.white.opacity(0.1))
            .cornerRadius(16, corners: isUser ? [.topLeft, .topRight, .bottomLeft] : [.topLeft, .topRight, .bottomRight])

            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 8)
    }
}

// Rounded corner helper
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
