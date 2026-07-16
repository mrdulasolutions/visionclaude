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
            // Start pinned to the newest message and stay pinned as content
            // grows — without this the view opens at the TOP of the history.
            .defaultScrollAnchor(.bottom)
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
        }
        .background(.black.opacity(0.3))
        .cornerRadius(16)
    }

    /// Scrolls after the current layout pass. LazyVStack hasn't laid out a
    /// just-appended row when onChange fires — scrolling immediately lands
    /// short of the newest message, which is why replies were getting cut off.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
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
                Text(isUser ? "You" : "Flux")
                    .font(.custom("Verdana-Bold", size: 10))
                    .foregroundColor(isUser ? .blue : .orange)
                    .textCase(.uppercase)

                // Message text
                Text(message.text)
                    .font(.custom("Verdana", size: 14))
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
                                .font(.custom("Verdana", size: 9))
                                .foregroundColor(.purple)
                        }
                        if message.toolCalls.count > 2 {
                            Text("+\(message.toolCalls.count - 2)")
                                .font(.custom("Verdana", size: 9))
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
