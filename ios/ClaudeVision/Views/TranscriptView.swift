import SwiftUI

struct TranscriptView: View {
    let messages: [TranscriptMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }
}

struct MessageBubble: View {
    let message: TranscriptMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(.white)
                    .multilineTextAlignment(message.role == .user ? .trailing : .leading)

                // Show tool call badges
                if !message.toolCalls.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.toolCalls.prefix(3), id: \.name) { tool in
                            Text(tool.name)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.3))
                                .cornerRadius(4)
                                .foregroundColor(.purple)
                        }
                        if message.toolCalls.count > 3 {
                            Text("+\(message.toolCalls.count - 3)")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.role == .user ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
            .cornerRadius(16)

            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 8)
    }
}
