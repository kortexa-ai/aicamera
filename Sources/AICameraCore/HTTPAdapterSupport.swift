import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EndpointRequestBuilder: Sendable {
    let endpoint: EndpointConfiguration
    let secrets: any SecretResolver

    func request(path defaultPath: String, method: String = "POST") async throws -> URLRequest {
        let path = endpoint.path ?? defaultPath
        let base = endpoint.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: suffix.isEmpty ? base : "\(base)/\(suffix)") else {
            throw HTTPAdapterError.invalidURL("\(base)/\(suffix)")
        }
        let timeout = endpoint.timeoutSeconds.isFinite
            ? min(600, max(0.1, endpoint.timeoutSeconds))
            : 20
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method

        if let secret = try await secrets.resolve(endpoint.auth) {
            request.setValue(endpoint.auth.prefix + secret, forHTTPHeaderField: endpoint.auth.header)
        }
        return request
    }
}

func checkedResponse(_ data: Data, _ response: HTTPURLResponse) throws -> Data {
    guard (200..<300).contains(response.statusCode) else {
        let body = String(data: data.prefix(2_048), encoding: .utf8) ?? "<non-text response>"
        throw HTTPAdapterError.httpStatus(response.statusCode, body)
    }
    return data
}

func multipartBody(
    fields: [(String, String)],
    fileField: String,
    fileName: String,
    mimeType: String,
    fileData: Data,
    boundary: String
) -> Data {
    var body = Data()
    func append(_ value: String) { body.append(Data(value.utf8)) }
    for (name, value) in fields {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
    append("Content-Type: \(mimeType)\r\n\r\n")
    body.append(fileData)
    append("\r\n--\(boundary)--\r\n")
    return body
}

func firstOpenAIMessageText(
    from data: Data,
    maximumCharacters: Int = AICameraContentLimits.agentCharacters
) throws -> String {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = root["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any] else {
        throw HTTPAdapterError.invalidResponse("missing choices[0].message")
    }
    if let content = message["content"] as? String {
        return content.aicameraLimited(to: maximumCharacters)
    }
    if let parts = message["content"] as? [[String: Any]] {
        var text = ""
        for part in parts where text.count < maximumCharacters {
            let value = (part["text"] as? String) ?? (part["content"] as? String) ?? ""
            text += String(value.prefix(maximumCharacters - text.count))
        }
        if !text.isEmpty { return text }
    }
    throw HTTPAdapterError.invalidResponse("missing textual message content")
}
