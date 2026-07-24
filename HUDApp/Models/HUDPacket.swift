import Foundation

enum HUDPacketType: String, Codable, Sendable {
    case clock
    case date
    case weather
    case battery
    case message
}

struct HUDPacket: Codable, Sendable {
    let type: HUDPacketType
    let text: String

    enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "Unable to encode HUD packet as UTF-8 string.")
            )
        }
        return string
    }

    func encodedData(appendingNewline: Bool = true) throws -> Data {
        let payload = try jsonString()
        let finalString = appendingNewline ? payload + "\n" : payload
        guard let data = finalString.data(using: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "Unable to convert HUD packet into UTF-8 data.")
            )
        }
        return data
    }
}
