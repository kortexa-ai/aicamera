// Native checks use only SHA-256-pinned public fixtures. No capture or Keychain access.
import AICameraCore
import CryptoKit
import Foundation

private enum CheckFailure: Error { case fixture, missingModel, cache, detection, cancellation, blockedMainActor }

@main private struct LocalVisionValidation {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("Local vision validation failed: \(error)"); exit(1) }
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw CheckFailure.fixture }
        let request = try fixture(path: CommandLine.arguments[1],
            expected: "5a9522051c3cec2bbd2f6323fccba32e8fbf3ddcc2b3e2fd46b04c720bc6f866", width: 768, height: 576)
        let closeup = try fixture(path: CommandLine.arguments[2],
            expected: "64a8ee417e67b63338c011ce8f86ed6338dfa97cb91fb20b353550775141a90a", width: 720, height: 1_280)
        let controller = BuiltinVisionModelController()
        for selected in BuiltinVisionModel.allCases {
            let constructionStart = Date()
            guard let client = controller.makeDetectionClient(modelID: selected.rawValue),
                  let reused = controller.makeDetectionClient(modelID: selected.rawValue) else { throw CheckFailure.missingModel }
            guard (client as AnyObject) === (reused as AnyObject) else { throw CheckFailure.cache }
            let construction = Date().timeIntervalSince(constructionStart)
            var pulseCount = 0
            let pulse = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                    pulseCount += 1
                }
            }
            let firstStart = Date()
            let first = try await client.detect(request)
            let firstSeconds = Date().timeIntervalSince(firstStart)
            pulse.cancel()
            if firstSeconds >= 0.1, pulseCount == 0 { throw CheckFailure.blockedMainActor }
            try validate(first)
            var warmSeconds = [Double]()
            for _ in 0..<3 {
                let start = Date()
                try validate(try await reused.detect(request))
                warmSeconds.append(Date().timeIntervalSince(start))
            }
            let cancelled = Task { try await client.detect(request) }
            try await Task.sleep(for: .milliseconds(1))
            let cancelStart = Date()
            cancelled.cancel()
            do { _ = try await cancelled.value; throw CheckFailure.cancellation }
            catch is CancellationError { }
            let cancelSeconds = Date().timeIntervalSince(cancelStart)
            try validate(try await reused.detect(request))
            let portrait = try await reused.detect(closeup)
            if selected != .yoloV3Tiny { try validate(portrait) }
            print("\(selected.name): construction=\(construction)s first=\(firstSeconds)s warm=\(warmSeconds)s cancellation-return=\(cancelSeconds)s UI-pulses=\(pulseCount), labels=\(Set(first.map(\.label)).sorted())")
            print("  Close-up fixture labels at confidence 0.25: \(Set(portrait.map(\.label)).sorted())")
        }
        try await checkRemoval(request: request)
        print("All local detectors: public fixture, cache identity, main-actor responsiveness, cancellation/recovery, and removal invalidation passed")
    }

    private static func fixture(path: String, expected: String, width: Int, height: Int) throws -> DetectionRequest {
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: path))
        guard SHA256.hash(data: jpeg).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw CheckFailure.fixture
        }
        return .init(jpegData: jpeg, imageWidth: width, imageHeight: height, confidence: 0.25)
    }

    private static func validate(_ detections: [Detection]) throws {
        guard detections.contains(where: { $0.label == "dog" }), detections.count <= AICameraContentLimits.detections else {
            print("Unexpected public-fixture labels: \(detections.map(\.label))")
            throw CheckFailure.detection
        }
        for detection in detections {
            let box = detection.boundingBox
            guard detection.confidence.isFinite, (0...1).contains(detection.confidence),
                  [box.x, box.y, box.width, box.height].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  box.x + box.width <= 1.000001, box.y + box.height <= 1.000001 else { throw CheckFailure.detection }
        }
    }

    @MainActor private static func checkRemoval(request: DetectionRequest) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aicamera-vision-cache-\(UUID())")
        let fixture = directory.appendingPathComponent("YOLOv3TinyInt8LUT.mlmodelc")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = BuiltinVisionModelController(modelDirectory: directory)
        // An empty directory is enough to establish readiness; constructing a client must not load it.
        guard let initial = controller.makeDetectionClient(modelID: BuiltinVisionModel.yoloV3Tiny.rawValue) else { throw CheckFailure.cache }
        let cancelled = Task { try await initial.detect(request) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure.cancellation }
        catch is CancellationError { }
        controller.remove(.yoloV3Tiny)
        guard !FileManager.default.fileExists(atPath: fixture.path),
              controller.makeDetectionClient(modelID: BuiltinVisionModel.yoloV3Tiny.rawValue) == nil else { throw CheckFailure.cache }
        _ = initial
    }
}
