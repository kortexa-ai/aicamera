import AICameraCore
import CoreImage
import CoreML
import Foundation

enum BuiltinVisionModel: String, CaseIterable, Identifiable {
    case yoloV3Tiny = "yolov3-tiny"
    case rfDetrMedium = "rfdetr-medium"
    case rfDetrLarge = "rfdetr-large"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .yoloV3Tiny: "YOLOv3 Tiny"
        case .rfDetrMedium: "RF-DETR Medium"
        case .rfDetrLarge: "RF-DETR Large"
        }
    }

    var sizeName: String {
        switch self {
        case .yoloV3Tiny: "Tiny"
        case .rfDetrMedium: "Medium"
        case .rfDetrLarge: "Large"
        }
    }

    var downloadSize: String {
        switch self {
        case .yoloV3Tiny: "0.009 GB"
        case .rfDetrMedium: "0.058 GB"
        case .rfDetrLarge: "0.059 GB"
        }
    }

    var summary: String {
        switch self {
        case .yoloV3Tiny: "Lightweight and fastest"
        case .rfDetrMedium: "Recommended balance"
        case .rfDetrLarge: "Higher accuracy"
        }
    }

    var detail: String {
        switch self {
        case .yoloV3Tiny:
            "Fastest, with the lowest memory and battery use."
        case .rfDetrMedium:
            "Balances accuracy and speed on Apple silicon."
        case .rfDetrLarge:
            "Highest accuracy, with more processing use. Best on M4 Pro, M3 Max, and faster Macs."
        }
    }

    fileprivate var compiledDirectoryName: String {
        switch self {
        case .yoloV3Tiny: "YOLOv3TinyInt8LUT.mlmodelc"
        case .rfDetrMedium: "RFDETRMediumFP16.mlmodelc"
        case .rfDetrLarge: "RFDETRLargeFP16.mlmodelc"
        }
    }

    fileprivate var inputSize: Int {
        switch self {
        case .yoloV3Tiny: 416
        case .rfDetrMedium: 576
        case .rfDetrLarge: 704
        }
    }
}

@MainActor
final class BuiltinVisionModelController: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    static let defaultModel = BuiltinVisionModel.rfDetrMedium
    nonisolated private static let artifactRevision = "893b757bc958fab3af1c4dcc96c5d0244f782d35"
    private static let yoloURL = URL(string: "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel")!
    private static let yoloSHA256 = "cde8af2528d6eca1d1580fdd0f0147cb6613d40ba962656b5f683c65f571870e"

    @Published private(set) var downloadProgress: Double?
    @Published private(set) var isCancellingDownload = false
    private var downloadGeneration: UInt64 = 0
    @Published private(set) var states: [BuiltinVisionModel: State] = [:]
    private let modelDirectory: URL
    private var downloadTask: Task<Void, Never>?
    private var downloadingModel: BuiltinVisionModel?
    private var clients: [BuiltinVisionModel: any DetectionClient] = [:]

    init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("AI Camera/Models", isDirectory: true)
        for model in BuiltinVisionModel.allCases {
            states[model] = FileManager.default.fileExists(atPath: compiledURL(for: model).path)
                ? .ready : .notDownloaded
        }
    }

    func state(for model: BuiltinVisionModel) -> State {
        states[model] ?? .notDownloaded
    }

    func isReady(_ model: BuiltinVisionModel) -> Bool {
        state(for: model) == .ready
    }

    var hasActiveDownload: Bool { downloadTask != nil }

    func download(_ model: BuiltinVisionModel) {
        guard downloadTask == nil, !isReady(model) else { return }
        downloadingModel = model
        downloadGeneration &+= 1
        let generation = downloadGeneration
        downloadProgress = nil
        isCancellingDownload = false
        states[model] = .downloading
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let progress: @Sendable (Double?) -> Void = { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.downloadGeneration == generation, self.downloadingModel == model,
                              !self.isCancellingDownload else { return }
                        self.downloadProgress = fraction
                    }
                }
                let compiled = switch model {
                case .yoloV3Tiny: try await Self.downloadAndCompileYOLO(progress: progress)
                case .rfDetrMedium, .rfDetrLarge: try await Self.downloadAndCompileRFDETR(model, progress: progress)
                }
                defer { try? FileManager.default.removeItem(at: compiled) }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(
                    at: modelDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let destination = compiledURL(for: model)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: compiled, to: destination)
                states[model] = .ready
            } catch is CancellationError {
                states[model] = .notDownloaded
            } catch {
                states[model] = Task.isCancelled ? .notDownloaded : .failed(error.localizedDescription)
            }
            downloadingModel = nil
            downloadTask = nil
            downloadProgress = nil
            isCancellingDownload = false
        }
    }

    func cancelDownload(_ model: BuiltinVisionModel) {
        guard downloadingModel == model else { return }
        isCancellingDownload = true
        downloadTask?.cancel()
    }

    func remove(_ model: BuiltinVisionModel) {
        if downloadingModel == model {
            cancelDownload(model)
            return
        }
        clients.removeValue(forKey: model)
        do {
            let destination = compiledURL(for: model)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            states[model] = .notDownloaded
        } catch {
            states[model] = .failed(error.localizedDescription)
        }
    }

    func makeDetectionClient(modelID: String?) -> (any DetectionClient)? {
        let selected = modelID.flatMap(BuiltinVisionModel.init(rawValue:)) ?? .yoloV3Tiny
        guard isReady(selected) else { return nil }
        if let client = clients[selected] { return client }
        let client = CoreMLDetectionClient(compiledModelURL: compiledURL(for: selected), kind: selected)
        clients[selected] = client
        return client
    }

    private func compiledURL(for model: BuiltinVisionModel) -> URL {
        modelDirectory.appendingPathComponent(model.compiledDirectoryName, isDirectory: true)
    }

    nonisolated private static func downloadAndCompileYOLO(progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let temporary = try await download(
            from: yoloURL,
            expectedSHA256: yoloSHA256,
            maximumBytes: 12 * 1_024 * 1_024,
            progress: { progress($0.fraction) }
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try await Task.detached(priority: .userInitiated) {
            try MLModel.compileModel(at: temporary)
        }.value
    }

    nonisolated private static func downloadAndCompileRFDETR(_ model: BuiltinVisionModel, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mlpackage", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let components = artifactComponents(for: model)
        let maximumTotal = Double(components.reduce(0) { $0 + $1.maximumBytes })
        var completedBytes: Int64 = 0
        for component in components {
            let previousBytes = completedBytes
            try Task.checkCancellation()
            let temporary = try await download(
                from: component.url,
                expectedSHA256: component.sha256,
                maximumBytes: component.maximumBytes,
                progress: { progress(min(0.99, Double(previousBytes + $0.receivedBytes) / maximumTotal)) }
            )
            defer { try? FileManager.default.removeItem(at: temporary) }
            let destination = packageURL.appendingPathComponent(component.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            completedBytes += (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        progress(1)
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try MLModel.compileModel(at: packageURL)
        }.value
    }

    nonisolated private static func download(
        from url: URL, expectedSHA256: String, maximumBytes: Int,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        try await VerifiedModelDownload.download(
            .init(url: url, sha256: expectedSHA256, maximumBytes: Int64(maximumBytes)), progress: progress
        )
    }

    nonisolated private static func artifactComponents(for model: BuiltinVisionModel) -> [ArtifactComponent] {
        let variant: String
        let manifestHash: String
        let modelHash: String
        let weightsHash: String
        switch model {
        case .rfDetrMedium:
            variant = "medium/rfdetr-medium.mlpackage"
            manifestHash = "fa81154026c5cf1dc2a5a2507994016f05d425d8352b9065503c06e1d4dfe419"
            modelHash = "f6d70188895c2dec698e49ca6a17728ef209f963070f1c3589513738ea43318e"
            weightsHash = "ef0ff4d221b0363df970c74fe084e9c30aaa4e7a068366b25ac5bf134c7f32ae"
        case .rfDetrLarge:
            variant = "large/rfdetr-large.mlpackage"
            manifestHash = "0e6f7296401cc14c485cd34210d86f2fc6aed436c6f1115f4ee0d51fd85a086d"
            modelHash = "d030bcec63eb35343c3d395aac6093ea2d0f44648bdde92875a92d355df0da32"
            weightsHash = "cb36a74ed39ced626e816df97338a28a7b743da23511b1b753a2574b03cea4f3"
        case .yoloV3Tiny:
            return []
        }
        func component(_ path: String, _ hash: String, _ limit: Int) -> ArtifactComponent {
            let remotePath = "\(variant)/\(path)"
            return ArtifactComponent(
                relativePath: path,
                url: URL(string: "https://huggingface.co/kortexa-ai/rf-detr-coreml/resolve/\(artifactRevision)/\(remotePath)")!,
                sha256: hash,
                maximumBytes: limit
            )
        }
        return [
            component("Manifest.json", manifestHash, 16 * 1_024),
            component("Data/com.apple.CoreML/model.mlmodel", modelHash, 1 * 1_024 * 1_024),
            component("Data/com.apple.CoreML/weights/weight.bin", weightsHash, 64 * 1_024 * 1_024),
        ]
    }

    private struct ArtifactComponent {
        let relativePath: String
        let url: URL
        let sha256: String
        let maximumBytes: Int
    }


}

/// One serial worker per downloaded model. Construction is cheap; loading and prediction stay off
/// the main actor. Core ML prediction cannot be interrupted, so cancellation is checked at its edges.
private actor CoreMLDetectionClient: DetectionClient {
    private let compiledModelURL: URL
    private let kind: BuiltinVisionModel
    private var model: MLModel?
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    init(compiledModelURL: URL, kind: BuiltinVisionModel) {
        self.compiledModelURL = compiledModelURL
        self.kind = kind
    }

    func detect(_ input: DetectionRequest) async throws -> [Detection] {
        try Task.checkCancellation()
        guard !input.jpegData.isEmpty, input.jpegData.count <= 16 * 1_024 * 1_024,
              input.confidence.isFinite else { throw DetectionError.invalidImage }
        if model == nil {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        }
        try Task.checkCancellation()
        guard let model else { throw DetectionError.invalidOutput }
        let result = try kind == .yoloV3Tiny
            ? YOLOCoreMLDetectionClient.detect(input, model: model, context: context)
            : RFDETRCoreMLDetectionClient.detect(input, model: model, inputSize: kind.inputSize, context: context)
        try Task.checkCancellation()
        return result
    }
}

private enum YOLOCoreMLDetectionClient {
    private static let inputSize = 416

    static func detect(_ input: DetectionRequest, model: MLModel, context: CIContext) throws -> [Detection] {
        let labels = model.modelDescription.classLabels as? [String] ?? []
        let pixelBuffer = try Self.pixelBuffer(from: input.jpegData, size: Self.inputSize, context: context)
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
              coordinates.shape[1].intValue == 4,
              coordinates.shape[0] == confidence.shape[0],
              (0...RFDETRPostprocessor.maximumQueries).contains(coordinates.shape[0].intValue),
              (1...RFDETRPostprocessor.maximumClasses).contains(confidence.shape[1].intValue),
              confidence.shape[1].intValue == labels.count else { throw DetectionError.invalidOutput }
        let count = min(coordinates.shape[0].intValue, confidence.shape[0].intValue, AICameraContentLimits.detections)
        let classCount = min(confidence.shape[1].intValue, labels.count)
        return (0..<count).compactMap { row in
            var classID: Int?
            var score = 0.0
            for column in 0..<classCount {
                let value = confidence[[row, column] as [NSNumber]].doubleValue
                if value.isFinite, value > score { score = value; classID = column }
            }
            guard let classID, score >= threshold else { return nil }
            return Self.detection(
                label: labels[classID], classID: classID, confidence: score,
                centerX: coordinates[[row, 0] as [NSNumber]].doubleValue,
                centerY: coordinates[[row, 1] as [NSNumber]].doubleValue,
                width: coordinates[[row, 2] as [NSNumber]].doubleValue,
                height: coordinates[[row, 3] as [NSNumber]].doubleValue
            )
        }
    }
}

private enum RFDETRCoreMLDetectionClient {
    static func detect(_ input: DetectionRequest, model: MLModel, inputSize: Int, context: CIContext) throws -> [Detection] {
        let pixelBuffer = try YOLOCoreMLDetectionClient.pixelBuffer(
            from: input.jpegData, size: inputSize, context: context
        )
        let tensor = try MLMultiArray(
            shape: [1, 3, NSNumber(value: inputSize), NSNumber(value: inputSize)],
            dataType: .float32
        )
        try Self.fillNormalizedRGB(tensor, from: pixelBuffer, size: inputSize)
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "tensors": MLFeatureValue(multiArray: tensor),
        ])
        let output = try model.prediction(from: features)
        try Task.checkCancellation()
        let arrays = output.featureNames.compactMap { output.featureValue(for: $0)?.multiArrayValue }
        guard let boxes = arrays.first(where: { $0.shape.count == 3 && $0.shape[2].intValue == 4 }),
              let logits = arrays.first(where: { $0.shape.count == 3 && $0.shape[2].intValue != 4 }) else {
            throw DetectionError.invalidOutput
        }
        let queryCount = boxes.shape[1].intValue
        let classCount = logits.shape[2].intValue
        guard boxes.shape[0].intValue == 1, logits.shape[0].intValue == 1,
              boxes.shape[1] == logits.shape[1],
              (1...RFDETRPostprocessor.maximumQueries).contains(queryCount),
              (1...RFDETRPostprocessor.maximumClasses).contains(classCount) else {
            throw DetectionError.invalidOutput
        }
        var boxValues = Array(repeating: 0.0, count: queryCount * 4)
        var logitValues = Array(repeating: 0.0, count: queryCount * classCount)
        for query in 0..<queryCount {
            for coordinate in 0..<4 {
                boxValues[query * 4 + coordinate] = boxes[[0, query, coordinate] as [NSNumber]].doubleValue
            }
            for classID in 0..<classCount {
                logitValues[query * classCount + classID] = logits[[0, query, classID] as [NSNumber]].doubleValue
            }
        }
        return RFDETRPostprocessor.detections(
            boxes: boxValues,
            logits: logitValues,
            queryCount: queryCount,
            classCount: classCount,
            confidence: input.confidence
        )
    }

    private static func fillNormalizedRGB(_ tensor: MLMultiArray, from pixelBuffer: CVPixelBuffer, size: Int) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw DetectionError.invalidImage }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let values = tensor.dataPointer.bindMemory(to: Float32.self, capacity: 3 * size * size)
        let plane = size * size
        let means: [Float32] = [0.485, 0.456, 0.406]
        let deviations: [Float32] = [0.229, 0.224, 0.225]
        for y in 0..<size {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in 0..<size {
                let source = row.advanced(by: x * 4)
                let destination = y * size + x
                let red = Float32(source[2]) / 255
                let green = Float32(source[1]) / 255
                let blue = Float32(source[0]) / 255
                values[destination] = (red - means[0]) / deviations[0]
                values[plane + destination] = (green - means[1]) / deviations[1]
                values[2 * plane + destination] = (blue - means[2]) / deviations[2]
            }
        }
    }
}

private extension YOLOCoreMLDetectionClient {
    static func pixelBuffer(from jpegData: Data, size: Int, context: CIContext) throws -> CVPixelBuffer {
        try Task.checkCancellation()
        guard let sourceImage = CIImage(data: jpegData) else { throw DetectionError.invalidImage }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw DetectionError.couldNotCreatePixelBuffer(status)
        }
        let resized = sourceImage.transformed(by: CGAffineTransform(
            scaleX: CGFloat(size) / sourceImage.extent.width,
            y: CGFloat(size) / sourceImage.extent.height
        ))
        context.render(
            resized, to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: size, height: size),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixelBuffer
    }

    static func detection(
        label: String, classID: Int, confidence: Double,
        centerX: Double, centerY: Double, width: Double, height: Double
    ) -> Detection? {
        guard [confidence, centerX, centerY, width, height].allSatisfy(\.isFinite),
              (0...1).contains(confidence) else { return nil }
        let left = min(max(centerX - width / 2, 0), 1)
        let top = min(max(centerY - height / 2, 0), 1)
        let right = min(max(centerX + width / 2, 0), 1)
        let bottom = min(max(centerY + height / 2, 0), 1)
        return Detection(
            label: label, classID: classID, confidence: confidence,
            boundingBox: .init(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
        )
    }
}

private enum DetectionError: LocalizedError {
    case invalidImage
    case couldNotCreatePixelBuffer(CVReturn)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .invalidImage: "The camera frame could not be decoded."
        case let .couldNotCreatePixelBuffer(status): "The model input buffer could not be created (\(status))."
        case .invalidOutput: "The object-detection model returned an unexpected result."
        }
    }
}
