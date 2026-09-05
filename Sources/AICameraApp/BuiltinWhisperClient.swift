import AICameraCore
import Foundation

actor BuiltinWhisperClient: TranscriptionClient {
    private let modelURL: URL
    private var engine: Engine?

    init(modelURL: URL) { self.modelURL = modelURL }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptEvent {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try cancellation.check()
            let input = try WhisperInput(wavData: request.wavData)
            if input.isSilent { return .init(text: "", mode: .final) }
            let engine: Engine
            if let loaded = self.engine { engine = loaded }
            else {
                let loaded = try Engine(modelURL: modelURL)
                try cancellation.check()
                self.engine = loaded
                engine = loaded
            }
            return try engine.transcribe(input, language: request.language, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func check() throws { if isCancelled { throw CancellationError() } }
    }

    private enum Failure: LocalizedError {
        case modelLoad, language, inference, invalidOutput
        var errorDescription: String? {
            switch self {
            case .modelLoad: "Whisper could not load the downloaded model. Remove it and download it again."
            case .language: "Whisper does not support the selected language. Choose Auto-detect or another language."
            case .inference: "Local transcription could not complete this audio window."
            case .invalidOutput: "Whisper returned an invalid or oversized transcript."
            }
        }
    }

    private final class Engine {
        private let context: OpaquePointer
        init(modelURL: URL) throws {
            guard let context = AICameraWhisperLoad(modelURL.path) else {
                throw Failure.modelLoad
            }
            self.context = context
        }
        deinit { AICameraWhisperFree(context) }

        func transcribe(_ input: WhisperInput, language: String?, cancellation: CancellationFlag) throws -> TranscriptEvent {
            try cancellation.check()
            let language = language ?? "auto"
            guard language.utf8.count <= 16, !language.contains("\0"),
                  AICameraWhisperSupportsLanguage(language) else { throw Failure.language }
            let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            let status = input.samples.withUnsafeBufferPointer {
                AICameraWhisperTranscribe(context, $0.baseAddress, Int32($0.count), language, threads, { data in
                    guard let data else { return true }
                    return Unmanaged<CancellationFlag>.fromOpaque(data).takeUnretainedValue().isCancelled
                }, Unmanaged.passUnretained(cancellation).toOpaque())
            }
            try cancellation.check()
            guard status == 0 else { throw Failure.inference }
            let count = AICameraWhisperSegmentCount(context)
            guard (0...256).contains(count) else { throw Failure.invalidOutput }
            var text = ModelTextBuffer()
            var hasText = false
            for index in 0..<count {
                try cancellation.check()
                let noSpeech = AICameraWhisperNoSpeechProbability(context, index)
                guard noSpeech.isFinite else { throw Failure.invalidOutput }
                if noSpeech >= 0.6 { continue }
                guard let segment = AICameraWhisperSegmentText(context, index) else { continue }
                let length = strnlen(segment, ModelTextBuffer.maximumBytes + 1)
                guard length <= ModelTextBuffer.maximumBytes else { throw Failure.invalidOutput }
                if length > 0 {
                    let bytes = UnsafeRawPointer(segment).assumingMemoryBound(to: UInt8.self)
                    try text.append(Array(UnsafeBufferPointer(start: bytes, count: length)))
                    hasText = true
                }
            }
            let result = hasText ? try text.finish() : ""
            return .init(text: result, mode: .final)
        }
    }
}
