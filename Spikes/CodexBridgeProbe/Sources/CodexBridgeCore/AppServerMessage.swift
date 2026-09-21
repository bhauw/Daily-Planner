import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .integer(value) = self else { return nil }
        return value
    }
}

public enum RequestID: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int64)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RequestId must be a string or int64"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        }
    }
}

public struct AppServerMessage: Decodable, Sendable, Equatable {
    public struct RPCError: Decodable, Sendable, Equatable {
        public let code: Int?
        public let message: String
    }

    enum Envelope: Sendable, Equatable {
        case response(RequestID)
        case notification
        case invalid
    }

    public let id: RequestID?
    public let method: String?
    let result: JSONValue?
    let params: JSONValue?
    public let error: RPCError?
    private let hasResult: Bool
    private let hasError: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case method
        case result
        case params
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.contains(.id) ? try container.decode(RequestID.self, forKey: .id) : nil
        method = container.contains(.method)
            ? try container.decode(String.self, forKey: .method)
            : nil
        result = container.contains(.result)
            ? try container.decode(JSONValue.self, forKey: .result)
            : nil
        params = container.contains(.params)
            ? try container.decode(JSONValue.self, forKey: .params)
            : nil
        error = container.contains(.error)
            ? try container.decode(RPCError.self, forKey: .error)
            : nil
        hasResult = container.contains(.result)
        hasError = container.contains(.error)
    }

    public var threadID: String? {
        result?["thread"]?["id"]?.stringValue
            ?? params?["threadId"]?.stringValue
    }

    public var turnID: String? {
        result?["turn"]?["id"]?.stringValue
            ?? params?["turn"]?["id"]?.stringValue
            ?? params?["turnId"]?.stringValue
    }

    public var turnStatus: String? {
        result?["turn"]?["status"]?.stringValue
            ?? params?["turn"]?["status"]?.stringValue
    }

    public var agentMessageText: String? {
        guard method == "item/completed",
              params?["item"]?["type"]?.stringValue == "agentMessage"
        else { return nil }
        return params?["item"]?["text"]?.stringValue
    }

    var envelope: Envelope {
        switch (id, method) {
        case let (id?, nil):
            guard hasResult != hasError else { return .invalid }
            return .response(id)
        case (nil, _?):
            guard !hasResult, !hasError else { return .invalid }
            return .notification
        case (_?, _?), (nil, nil):
            return .invalid
        }
    }

    public static func decode(_ line: String) throws -> AppServerMessage {
        try JSONDecoder().decode(AppServerMessage.self, from: Data(line.utf8))
    }
}
