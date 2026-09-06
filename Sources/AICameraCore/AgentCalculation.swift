import Foundation

public enum AgentCalculationError: LocalizedError, Equatable {
    case invalidExpression, limitExceeded, divisionByZero, outOfRange
    public var errorDescription: String? {
        switch self {
        case .invalidExpression: return "Use decimal numbers, parentheses, and +, -, *, or /. No variables, functions, percentages, or units."
        case .limitExceeded: return "The calculation exceeds its input, nesting, or operation limit."
        case .divisionByZero: return "Cannot divide by zero."
        case .outOfRange: return "The calculation exceeds the supported decimal range."
        }
    }
}

public struct AgentCalculationResult: Equatable, Sendable {
    public let expression: String
    public let value: String
    public let rounded: Bool
    public var toolResult: [String: Any] {
        ["ok": true, "expression": expression, "result": value, "rounded": rounded,
         "decimalPlaces": AgentCalculation.decimalPlaces,
         "method": "Local decimal arithmetic; rounds each operation to at most 12 decimal places.",
         "scope": "Arithmetic only. Input facts, units, rates, and assumptions are not verified."]
    }
}

/// A small arithmetic grammar, never an interpreter or code-evaluation API. Bounds apply before
/// parsing and after every operation; fixed decimal rounding is explicit in the tool result.
public enum AgentCalculation {
    public static let maximumExpressionBytes = 512
    public static let maximumOperations = 64
    public static let maximumDepth = 16
    public static let decimalPlaces = 12
    private static let maximumMagnitude = Decimal(string: "1000000000000000000000000")!

    public static func evaluate(_ expression: String) throws -> AgentCalculationResult {
        guard expression.utf8.count <= maximumExpressionBytes else { throw AgentCalculationError.limitExceeded }
        var parser = Parser(bytes: Array(expression.utf8))
        var value = try parser.expression(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count else { throw AgentCalculationError.invalidExpression }
        if value == 0 { value = 0 } // Canonical zero, including rounded negative zero.
        return .init(expression: expression, value: NSDecimalString(&value, Locale(identifier: "en_US_POSIX")), rounded: parser.rounded)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var operations = 0
        var rounded = false

        mutating func space() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func take(_ byte: UInt8) -> Bool {
            space()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func expression(depth: Int) throws -> Decimal {
            var value = try term(depth: depth)
            while true {
                if take(43) { value = try apply(43, value, term(depth: depth)) }
                else if take(45) { value = try apply(45, value, term(depth: depth)) }
                else { return value }
            }
        }
        mutating func term(depth: Int) throws -> Decimal {
            var value = try factor(depth: depth)
            while true {
                if take(42) { value = try apply(42, value, factor(depth: depth)) }
                else if take(47) { value = try apply(47, value, factor(depth: depth)) }
                else { return value }
            }
        }
        mutating func factor(depth: Int) throws -> Decimal {
            guard depth <= maximumDepth else { throw AgentCalculationError.limitExceeded }
            if take(43) { return try apply(43, 0, factor(depth: depth + 1)) }
            if take(45) { return try apply(45, 0, factor(depth: depth + 1)) }
            if take(40) {
                let value = try expression(depth: depth + 1)
                guard take(41) else { throw AgentCalculationError.invalidExpression }
                return value
            }
            space()
            let start = index
            var digits = 0, fractionDigits = 0
            var decimalPoint = false
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) {
                    digits += 1
                    if decimalPoint { fractionDigits += 1 }
                } else if byte == 46, !decimalPoint { decimalPoint = true }
                else { break }
                index += 1
            }
            guard digits > 0 else { throw AgentCalculationError.invalidExpression }
            guard digits <= 36, fractionDigits <= decimalPlaces else { throw AgentCalculationError.limitExceeded }
            guard let value = Decimal(string: String(decoding: bytes[start..<index], as: UTF8.self),
                                      locale: Locale(identifier: "en_US_POSIX")) else { throw AgentCalculationError.invalidExpression }
            return try checked(value)
        }
        func checked(_ value: Decimal) throws -> Decimal {
            guard !value.isNaN, value >= -maximumMagnitude, value <= maximumMagnitude else { throw AgentCalculationError.outOfRange }
            return value
        }
        mutating func apply(_ operation: UInt8, _ left: Decimal, _ right: Decimal) throws -> Decimal {
            operations += 1
            guard operations <= maximumOperations else { throw AgentCalculationError.limitExceeded }
            var a = left, b = right, value = Decimal()
            let status: NSDecimalNumber.CalculationError
            switch operation {
            case 43: status = NSDecimalAdd(&value, &a, &b, .plain)
            case 45: status = NSDecimalSubtract(&value, &a, &b, .plain)
            case 42: status = NSDecimalMultiply(&value, &a, &b, .plain)
            case 47:
                guard b != 0 else { throw AgentCalculationError.divisionByZero }
                status = NSDecimalDivide(&value, &a, &b, .plain)
            default: throw AgentCalculationError.invalidExpression
            }
            guard status == .noError || status == .lossOfPrecision else { throw AgentCalculationError.outOfRange }
            _ = try checked(value)
            var quantized = Decimal()
            NSDecimalRound(&quantized, &value, decimalPlaces, .plain)
            rounded = rounded || status == .lossOfPrecision || quantized != value
            return try checked(quantized)
        }
    }
}
