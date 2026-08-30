import AICameraCore
import CoreImage
import CoreML
import CryptoKit
import Foundation

@MainActor
final class BuiltinVisionModelController: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    static let modelName = "YOLOv3 Tiny"
    static let modelURL = URL(string: "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel")!
    static let expectedSHA256 = "cde8af2528d6eca1d1580fdd0f0147cb6613d40ba962656b5f683c65f571870e"
    private static let maximumDownloadBytes = 12 * 1_024 * 1_024

    @Published private(set) var state: State
    private let compiledModelURL: URL
    private var downloadTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("AI Camera/Models", isDirectory: true)
        compiledModelURL = support.appendingPathComponent("YOLOv3TinyInt8LUT.mlmodelc", isDirectory: true)
        state = FileManager.default.fileExists(atPath: compiledModelURL.path) ? .ready : .notDownloaded
    }

    var isReady: Bool { state == .ready }

    func download() {
        guard downloadTask == nil, !isReady else { return }
        state = .downloading
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: Self.modelURL)
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      response.url?.host?.lowercased() == "ml-assets.apple.com" else {
                    throw ModelError.invalidResponse
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard byteCount > 0, byteCount <= Self.maximumDownloadBytes else {
                    throw ModelError.invalidSize
                }
                let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == Self.expectedSHA256 else { throw ModelError.integrityMismatch }

                let compiled = try await Task.detached(priority: .userInitiated) {
                    try MLModel.compileModel(at: temporaryURL)
                }.value
                let parent = self.compiledModelURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if FileManager.default.fileExists(atPath: self.compiledModelURL.path) {
                    try FileManager.default.removeItem(at: self.compiledModelURL)
                }
                try FileManager.default.moveItem(at: compiled, to: self.compiledModelURL)
                self.state = .ready
            } catch is CancellationError {
                self.state = .notDownloaded
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.downloadTask = nil
        }
    }

    func remove() {
        downloadTask?.cancel()
        downloadTask = nil
        do {
            if FileManager.default.fileExists(atPath: compiledModelURL.path) {
                try FileManager.default.removeItem(at: compiledModelURL)
            }
            state = .notDownloaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func makeDetectionClient() -> (any DetectionClient)? {
        guard isReady else { return nil }
        do {
            return try CoreMLDetectionClient(compiledModelURL: compiledModelURL)
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    private enum ModelError: LocalizedError {
        case invalidResponse
        case invalidSize
        case integrityMismatch

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The Apple model server returned an invalid response."
            case .invalidSize: return "The downloaded model has an unexpected size."
            case .integrityMismatch: return "The downloaded model failed its integrity check."
            }
        }
    }
}

private final class CoreMLDetectionClient: DetectionClient, @unchecked Sendable {
    private static let inputSize = 416

    private let model: MLModel
    private let labels: [String]
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(compiledModelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        labels = model.modelDescription.classLabels as? [String] ?? []
    }

    func detect(_ input: DetectionRequest) async throws -> [Detection] {
        let model = model
        let labels = labels
        let context = context
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let sourceImage = CIImage(data: input.jpegData) else {
                throw DetectionError.invalidImage
            }
            let inputSize = CoreMLDetectionClient.inputSize
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                inputSize,
                inputSize,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw DetectionError.couldNotCreatePixelBuffer(status)
            }

            let resizedImage = sourceImage.transformed(by: CGAffineTransform(
                scaleX: CGFloat(inputSize) / sourceImage.extent.width,
                y: CGFloat(inputSize) / sourceImage.extent.height
            ))
            context.render(
                resizedImage,
                to: pixelBuffer,
                bounds: CGRect(x: 0, y: 0, width: inputSize, height: inputSize),
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            let threshold = min(max(input.confidence, 0), 1)
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: pixelBuffer),
                "confidenceThreshold": MLFeatureValue(double: threshold),
                "iouThreshold": MLFeatureValue(double: 0.45),
            ])
            let output = try model.prediction(from: features)
            try Task.checkCancellation()

            guard let coordinates = output.featureValue(for: "coordinates")?.multiArrayValue,
                  let confidence = output.featureValue(for: "confidence")?.multiArrayValue,
                  coordinates.shape.count == 2,
                  confidence.shape.count == 2,
                  coordinates.shape[1].intValue == 4 else {
                throw DetectionError.invalidOutput
            }
            let count = min(
                coordinates.shape[0].intValue,
                confidence.shape[0].intValue,
                AICameraContentLimits.detections
            )
            let classCount = min(confidence.shape[1].intValue, labels.count)

            return (0..<count).compactMap { row in
                var classID: Int?
                var score = 0.0
                for column in 0..<classCount {
                    let value = confidence[[row, column] as [NSNumber]].doubleValue
                    if value > score {
                        score = value
                        classID = column
                    }
                }
                guard let classID, score >= threshold else { return nil }

                let centerX = coordinates[[row, 0] as [NSNumber]].doubleValue
                let centerY = coordinates[[row, 1] as [NSNumber]].doubleValue
                let width = coordinates[[row, 2] as [NSNumber]].doubleValue
                let height = coordinates[[row, 3] as [NSNumber]].doubleValue
                let left = min(max(centerX - width / 2, 0), 1)
                let top = min(max(centerY - height / 2, 0), 1)
                let right = min(max(centerX + width / 2, 0), 1)
                let bottom = min(max(centerY + height / 2, 0), 1)
                return Detection(
                    label: labels[classID],
                    classID: classID,
                    confidence: score,
                    boundingBox: .init(
                        x: left,
                        y: top,
                        width: max(right - left, 0),
                        height: max(bottom - top, 0)
                    )
                )
            }
        }.value
    }

    private enum DetectionError: LocalizedError {
        case invalidImage
        case couldNotCreatePixelBuffer(CVReturn)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "The camera frame could not be decoded."
            case let .couldNotCreatePixelBuffer(status):
                return "The YOLO input buffer could not be created (\(status))."
            case .invalidOutput: return "The YOLO model returned an unexpected result."
            }
        }
    }
}
