import CryptoKit
import Foundation
import XCTest
@testable import AICameraCore

final class VerifiedModelDownloadTests: XCTestCase {
    func testChunksAreWrittenAndHashedWithoutRetainingTheWholeBody() async throws {
        let bytes = Data((0..<80_000).map { UInt8($0 % 251) })
        let url = fixture(chunks: [bytes.prefix(13), bytes.dropFirst(13)], expectedLength: bytes.count)
        let file = try await VerifiedModelDownload.download(artifact(url, data: bytes), configuration: sessionConfiguration)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testUnknownLengthOverflowRemovesItsPartialFile() async throws {
        let bytes = Data(repeating: 42, count: 8)
        let url = fixture(chunks: [bytes, bytes], expectedLength: nil)
        do {
            _ = try await VerifiedModelDownload.download(artifact(url, data: bytes), configuration: sessionConfiguration)
            XCTFail("Overflow succeeded")
        } catch { XCTAssertEqual(error as? VerifiedModelDownload.Failure, .invalidSize) }
        XCTAssertTrue(try partialFiles(for: url).isEmpty)
    }

    func testIntegrityMismatchRemovesItsPartialFile() async throws {
        let url = fixture(chunks: [Data([1, 2])], expectedLength: 2)
        do {
            _ = try await VerifiedModelDownload.download(artifact(url, data: Data([3, 4])), configuration: sessionConfiguration)
            XCTFail("Corrupt artifact succeeded")
        } catch { XCTAssertEqual(error as? VerifiedModelDownload.Failure, .integrityMismatch) }
        XCTAssertTrue(try partialFiles(for: url).isEmpty)
    }

    func testDeclaredOversizeAndHTTPFailureAreRejected() async throws {
        for (length, status, expected) in [(100, 200, VerifiedModelDownload.Failure.invalidSize), (2, 404, .invalidResponse)] {
            let url = fixture(chunks: [], expectedLength: length, status: status)
            do {
                _ = try await VerifiedModelDownload.download(artifact(url, data: Data([1, 2])), configuration: sessionConfiguration)
                XCTFail("Invalid response succeeded")
            } catch { XCTAssertEqual(error as? VerifiedModelDownload.Failure, expected) }
            XCTAssertTrue(try partialFiles(for: url).isEmpty)
        }
    }

    func testCancellationStopsTransferAndCleansPartialFile() async throws {
        let started = expectation(description: "started")
        let stopped = expectation(description: "stopped")
        let url = fixture(chunks: [Data([1, 2])], expectedLength: nil, hangs: true,
                          started: { started.fulfill() }, stopped: { stopped.fulfill() })
        let transfer = Task {
            try await VerifiedModelDownload.download(artifact(url, data: Data(count: 10)), configuration: sessionConfiguration)
        }
        await fulfillment(of: [started], timeout: 3)
        transfer.cancel()
        do { _ = try await transfer.value; XCTFail("Cancelled transfer succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertTrue(try partialFiles(for: url).isEmpty)
    }

    private var sessionConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtifactURLProtocol.self]
        return config
    }

    private func artifact(_ url: URL, data: Data) -> ModelArtifact {
        .init(url: url, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
              maximumBytes: Int64(data.count), expectedBytes: Int64(data.count))
    }

    private func partialFiles(for url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                                                    includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(url.lastPathComponent) }
    }

    private func fixture(chunks: [Data], expectedLength: Int?, status: Int = 200, hangs: Bool = false,
                         started: @escaping @Sendable () -> Void = {}, stopped: @escaping @Sendable () -> Void = {}) -> URL {
        let url = URL(string: "https://models.invalid/\(UUID()).bin")!
        ArtifactURLProtocol.install(.init(chunks: chunks, expectedLength: expectedLength, status: status,
                                          hangs: hangs, started: started, stopped: stopped), for: url)
        return url
    }
}

private final class ArtifactURLProtocol: URLProtocol {
    struct Plan: Sendable {
        let chunks: [Data]
        let expectedLength: Int?
        let status: Int
        let hangs: Bool
        let started: @Sendable () -> Void
        let stopped: @Sendable () -> Void
    }
    private static let lock = NSLock()
    private static var plans: [URL: Plan] = [:]
    private var plan: Plan?
    static func install(_ plan: Plan, for url: URL) { lock.lock(); plans[url] = plan; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "models.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        plan = request.url.flatMap { Self.plans.removeValue(forKey: $0) }
        Self.lock.unlock()
        guard let plan, let url = request.url else { return }
        let headers = plan.expectedLength.map { ["Content-Length": String($0)] }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: plan.status,
                                                            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
        plan.started()
        if !plan.hangs { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { plan?.stopped() }
}
