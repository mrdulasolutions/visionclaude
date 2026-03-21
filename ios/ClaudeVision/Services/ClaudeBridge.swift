import Foundation

actor ClaudeBridge {
    private let session: URLSession
    private var conversationId: String?
    private var config: ClaudeConfig

    init(config: ClaudeConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 60 // Claude tool loops can be slow
        sessionConfig.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: sessionConfig)
    }

    func updateConfig(_ config: ClaudeConfig) {
        self.config = config
    }

    func chat(text: String, images: [Data] = []) async throws -> ChatResponse {
        let base64Images = images.map { $0.base64EncodedString() }

        let request = ChatRequest(
            text: text,
            images: base64Images,
            conversation_id: conversationId
        )

        var urlRequest = URLRequest(url: config.chatURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeBridgeError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeBridgeError.serverError(statusCode: httpResponse.statusCode, message: body)
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        conversationId = chatResponse.conversation_id
        return chatResponse
    }

    func checkHealth() async throws -> HealthResponse {
        let (data, _) = try await session.data(from: config.healthURL)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    func resetConversation() {
        conversationId = nil
    }
}

enum ClaudeBridgeError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from gateway"
        case .serverError(let code, let message):
            return "Gateway error (\(code)): \(message)"
        }
    }
}
