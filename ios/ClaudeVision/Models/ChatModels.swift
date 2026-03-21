import Foundation

struct ChatRequest: Encodable {
    let text: String
    let images: [String] // base64 JPEG strings
    let conversation_id: String?
}

struct ChatResponse: Decodable {
    let text: String
    let tool_calls: [ToolCallResult]
    let conversation_id: String
}

struct ToolCallResult: Decodable {
    let name: String
    let result: AnyCodable
}

struct HealthResponse: Decodable {
    let status: String
    let uptime: Double
}

// Wrapper for decoding arbitrary JSON values
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            value = NSNull()
        }
    }
}

struct TranscriptMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date
    let toolCalls: [ToolCallResult]

    enum Role {
        case user
        case assistant
    }

    init(role: Role, text: String, toolCalls: [ToolCallResult] = []) {
        self.role = role
        self.text = text
        self.timestamp = Date()
        self.toolCalls = toolCalls
    }
}
