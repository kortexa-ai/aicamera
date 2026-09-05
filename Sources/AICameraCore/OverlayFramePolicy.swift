import CoreFoundation
import Foundation

/// Fixed-size messages from the isolated overlay page. Validate before decoding pixel storage.
public enum OverlayFramePolicy {
    public static let width = 640
    public static let height = 360
    public static let pixelBytes = width * height * 4
    public static let base64Bytes = ((pixelBytes + 2) / 3) * 4

    public struct Frame {
        public let sequence: Int
        public let pixels: Data
    }

    public static func decode(_ body: [String: Any], generation: String, after sequence: Int) -> Frame? {
        guard body["generation"] as? String == generation,
              integer(body["w"]) == width, integer(body["h"]) == height,
              let next = integer(body["seq"]), next > sequence,
              let encoded = body["b64"] as? String, encoded.utf8.count == base64Bytes,
              let pixels = Data(base64Encoded: encoded), pixels.count == pixelBytes else { return nil }
        return Frame(sequence: next, pixels: pixels)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...Double(Int32.max)).contains(number.doubleValue),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
}
