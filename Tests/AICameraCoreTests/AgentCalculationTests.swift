import XCTest
@testable import AICameraCore

final class AgentCalculationTests: XCTestCase {
    func testPrecedenceParenthesesSignsAndDecimalArithmetic() throws {
        for (expression, result) in ["2 + 3 * 4": "14", "(2 + 3) * 4": "20",
                                     "10 - 3 - 2": "5", "24 / 4 / 2": "3", "-2 * -(3 + 4)": "14",
                                     ".5 + 1.": "1.5", "0.1 + 0.2": "0.3", "1 / 8": "0.125",
                                     "200 * 15 / 100": "30", "(19.99 - 17.50) * 12": "29.88",
                                     " 2 +\n3\t": "5", "-0": "0", "2--3": "5"] {
            let calculation = try AgentCalculation.evaluate(expression)
            XCTAssertEqual(calculation.value, result, expression)
            XCTAssertFalse(calculation.rounded, expression)
        }
    }

    func testRepeatingAndTinyResultsReportRoundingAtEachStep() throws {
        for (expression, result) in ["1 / 3": "0.333333333333", "1 / 6": "0.166666666667",
                                     "-1 / 6": "-0.166666666667", "0.000000000001 / 2": "0.000000000001",
                                     "0.000000000001 / 3": "0", "(1 / 3) * 3": "0.999999999999",
                                     "(1 / 3) * 0": "0"] {
            let calculation = try AgentCalculation.evaluate(expression)
            XCTAssertEqual(calculation.value, result, expression)
            XCTAssertTrue(calculation.rounded, expression)
        }
        XCTAssertFalse(try AgentCalculation.evaluate("0.123456789012").rounded)
    }

    func testInvalidGrammarNeverAcceptsCodeUnitsOrPartialNumbers() {
        for expression in ["", " ", ".", "1.2.3", "1e3", "1 2", "1,000", "2(3)", "()", "(1+2", "1+2)",
                           "1+", "*2", "2**3", "2^3", "20%", "sqrt(4)", "USD 10", "x+1", "1;2",
                           "__import__('os')", "Infinity", "NaN", "2＋3", "2−3", "١+٢", "1\u{0}+2"] {
            XCTAssertThrowsError(try AgentCalculation.evaluate(expression), expression)
        }
    }

    func testDivisionByZeroAndIntermediateMagnitudeAreRejected() throws {
        for expression in ["1/0", "3/(2-2)", "1/(0.000000000001/3)"] {
            XCTAssertThrowsError(try AgentCalculation.evaluate(expression)) {
                XCTAssertEqual($0 as? AgentCalculationError, .divisionByZero)
            }
        }
        XCTAssertEqual(try AgentCalculation.evaluate("1000000000000000000000000").value, "1000000000000000000000000")
        for expression in ["1000000000000000000000001", "1000000000000000000000000*2", "1000000000000000000000000/0.1",
                           "(1000000000000000000000000 * 2) / 2"] {
            XCTAssertThrowsError(try AgentCalculation.evaluate(expression)) {
                XCTAssertEqual($0 as? AgentCalculationError, .outOfRange)
            }
        }
    }

    func testInputOperationNestingAndLiteralBounds() throws {
        let allowed = Array(repeating: "1", count: 65).joined(separator: "+")
        XCTAssertEqual(try AgentCalculation.evaluate(allowed).value, "65")
        let nested = String(repeating: "(", count: 16) + "1" + String(repeating: ")", count: 16)
        XCTAssertEqual(try AgentCalculation.evaluate(nested).value, "1")
        for expression in [allowed + "+1", "(" + nested + ")", String(repeating: "+", count: 17) + "1",
                           String(repeating: "0", count: 37), "0.1234567890123", String(repeating: " ", count: 513)] {
            XCTAssertThrowsError(try AgentCalculation.evaluate(expression)) {
                XCTAssertEqual($0 as? AgentCalculationError, .limitExceeded)
            }
        }
    }

    func testToolIsStrictOptionalAndPreservesAssumptionsAndRounding() throws {
        let script = ScriptOverlayConfiguration()
        XCTAssertEqual(AgentToolCommand.parse(name: "calculate", arguments: #"{"expression":"200*15/100"}"#, script: script), .calculate("200*15/100"))
        for bad in [#"{}"#, #"{"expression":2}"#, #"{"expression":null}"#, #"{"expression":" "}"#,
                    #"{"expression":"2+3","unit":"USD"}"#] {
            XCTAssertNil(AgentToolCommand.parse(name: "calculate", arguments: bad, script: script))
        }
        let disabled = AgentToolCatalog.definitions(capabilities: .init(notes: true), script: script)
        XCTAssertFalse(disabled.contains { $0["name"] as? String == "calculate" })
        let enabled = AgentToolCatalog.definitions(capabilities: .init(calculation: true), script: script)
        XCTAssertEqual(enabled.count, 1)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(enabled))
        let result = try AgentCalculation.evaluate("1 / 3")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result.toolResult))
        XCTAssertEqual(result.toolResult["result"] as? String, "0.333333333333")
        XCTAssertEqual(result.toolResult["rounded"] as? Bool, true)
        XCTAssertTrue(AgentToolCatalog.instructions(capabilities: .init(calculation: true)).contains("calculation does not verify"))
        XCTAssertFalse(AgentToolCatalog.instructions(capabilities: .init()).contains("Use calculate"))
    }

    func testKnownComparisonCanContinueIntoAnExistingInformationCard() throws {
        var turn = AgentToolTurn()
        XCTAssertTrue(turn.admit(callID: "arithmetic")); turn.endedResponse()
        let result = try AgentCalculation.evaluate("(19.99 - 17.50) * 12")
        turn.completed(callID: "arithmetic")
        XCTAssertEqual(turn.takeNext(), .continueResponse(allowTools: true))
        XCTAssertTrue(turn.admit(callID: "display"))
        let request = AgentCardRequest(title: "Annual difference", body: "$\(result.value)",
                                      source: "Assumes 12 months at the two given monthly prices.", style: .metric)
        XCTAssertNotNil(AgentPresentationState().show(request))
        turn.completed(callID: "display"); turn.endedResponse()
        XCTAssertEqual(turn.takeNext(), .continueResponse(allowTools: true))
    }
}
