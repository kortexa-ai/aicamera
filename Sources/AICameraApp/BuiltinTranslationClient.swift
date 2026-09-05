import AICameraCore
import Foundation
import llama

actor BuiltinTranslationClient: TranslationClient {
    private let modelURL: URL
    private var engine: Engine?

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func translate(_ request: TranslationRequest) async throws -> String {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try cancellation.check()
            let engine: Engine
            if let loaded = self.engine {
                engine = loaded
            } else {
                let loaded = try Engine(modelURL: modelURL, cancellation: cancellation)
                try cancellation.check()
                self.engine = loaded
                engine = loaded
            }
            return try engine.translate(request, cancellation: cancellation)
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

    private enum Runtime {
        // llama's backend is process-global. Engine teardown must not free another client's backend.
        static let initialized: Void = { llama_backend_init() }()
    }

    private final class Engine {
        private enum TranslationError: LocalizedError {
            case modelLoadFailed, contextCreationFailed, tokenizationFailed, promptTooLong, inferenceFailed, outputLimitReached

            var errorDescription: String? {
                switch self {
                case .modelLoadFailed: return "HY-MT2 could not be loaded."
                case .contextCreationFailed: return "The local translation context could not be created."
                case .tokenizationFailed: return "The translation prompt could not be tokenized."
                case .promptTooLong: return "The transcript is too long for local translation."
                case .inferenceFailed: return "Local translation failed during inference."
                case .outputLimitReached: return "The translation exceeded its output limit. Try a shorter utterance."
                }
            }
        }

        private let model: OpaquePointer
        private let context: OpaquePointer
        private let vocabulary: OpaquePointer
        private let sampler: UnsafeMutablePointer<llama_sampler>
        private var batch: llama_batch

        init(modelURL: URL, cancellation: CancellationFlag) throws {
            _ = Runtime.initialized
            var modelParameters = llama_model_default_params()
            modelParameters.n_gpu_layers = 99
            modelParameters.progress_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            modelParameters.progress_callback = { _, data in
                guard let data else { return false }
                return !Unmanaged<CancellationFlag>.fromOpaque(data).takeUnretainedValue().isCancelled
            }
            guard let model = llama_model_load_from_file(modelURL.path, modelParameters) else {
                try cancellation.check()
                throw TranslationError.modelLoadFailed
            }
            var contextParameters = llama_context_default_params()
            contextParameters.n_ctx = 2_048
            contextParameters.n_batch = 2_048
            let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
            contextParameters.n_threads = Int32(threads)
            contextParameters.n_threads_batch = Int32(threads)
            guard let context = llama_init_from_model(model, contextParameters) else {
                llama_model_free(model)
                throw TranslationError.contextCreationFailed
            }
            let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(20))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.6, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.2))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(0xA1CA))
            self.model = model
            self.context = context
            self.vocabulary = llama_model_get_vocab(model)
            self.sampler = sampler
            self.batch = llama_batch_init(2_048, 0, 1)
        }

        deinit {
            llama_sampler_free(sampler)
            llama_batch_free(batch)
            llama_free(context)
            llama_model_free(model)
        }

        func translate(_ request: TranslationRequest, cancellation: CancellationFlag) throws -> String {
            try cancellation.check()
            guard request.text.utf8.count <= ModelTextBuffer.maximumBytes else { throw TranslationError.promptTooLong }
            llama_set_abort_callback(context, { data in
                guard let data else { return true }
                return Unmanaged<CancellationFlag>.fromOpaque(data).takeUnretainedValue().isCancelled
            }, Unmanaged.passUnretained(cancellation).toOpaque())
            defer { llama_set_abort_callback(context, nil, nil) }
            let target = Self.languageName(for: request.targetLanguage)
            let sourceClause = request.sourceLanguage == "auto"
                ? ""
                : " from \(Self.languageName(for: request.sourceLanguage))"
            let instruction = "Translate the following text\(sourceClause) into \(target). Only output the translated result without any additional explanation:\n\n\(request.text)"
            let tokens = try tokenize(formatPrompt(instruction))
            guard tokens.count < 1_700 else { throw TranslationError.promptTooLong }
            llama_memory_clear(llama_get_memory(context), true)
            llama_sampler_reset(sampler)
            clearBatch()
            for (position, token) in tokens.enumerated() {
                add(token: token, position: Int32(position), logits: position == tokens.count - 1)
            }
            try decode(cancellation: cancellation)

            var result = ModelTextBuffer()
            var currentPosition = Int32(tokens.count)
            for _ in 0..<256 {
                try cancellation.check()
                let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
                if llama_vocab_is_eog(vocabulary, token) { return try result.finish() }
                try result.append(piece(for: token))
                clearBatch()
                add(token: token, position: currentPosition, logits: true)
                try decode(cancellation: cancellation)
                currentPosition += 1
            }
            throw TranslationError.outputLimitReached
        }

        private func decode(cancellation: CancellationFlag) throws {
            try cancellation.check()
            let status = llama_decode(context, batch)
            try cancellation.check()
            guard status == 0 else { throw TranslationError.inferenceFailed }
        }

        private func tokenize(_ text: String) throws -> [llama_token] {
            let capacity = text.utf8.count + 16
            let storage = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
            defer { storage.deallocate() }
            let count = llama_tokenize(vocabulary, text, Int32(text.utf8.count), storage, Int32(capacity), true, true)
            guard count > 0 else { throw TranslationError.tokenizationFailed }
            return Array(UnsafeBufferPointer(start: storage, count: Int(count)))
        }

        private func formatPrompt(_ instruction: String) -> String {
            let template = llama_model_chat_template(model, nil)
            return "user".withCString { role in
                instruction.withCString { content in
                    var message = llama_chat_message(role: role, content: content)
                    var output = [CChar](repeating: 0, count: max(512, instruction.utf8.count * 2 + 256))
                    var count = output.withUnsafeMutableBufferPointer { buffer in
                        llama_chat_apply_template(template, &message, 1, true, buffer.baseAddress, Int32(buffer.count))
                    }
                    if count > output.count {
                        output = [CChar](repeating: 0, count: Int(count))
                        count = output.withUnsafeMutableBufferPointer { buffer in
                            llama_chat_apply_template(template, &message, 1, true, buffer.baseAddress, Int32(buffer.count))
                        }
                    }
                    guard count > 0 else { return instruction }
                    return String(decoding: output.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
                }
            }
        }

        private func clearBatch() { batch.n_tokens = 0 }

        private func add(token: llama_token, position: llama_pos, logits: Bool) {
            let index = Int(batch.n_tokens)
            batch.token[index] = token
            batch.pos[index] = position
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = 0
            batch.logits[index] = logits ? 1 : 0
            batch.n_tokens += 1
        }

        private func piece(for token: llama_token) throws -> [UInt8] {
            var storage = [CChar](repeating: 0, count: 256)
            var count = llama_token_to_piece(vocabulary, token, &storage, Int32(storage.count), 0, true)
            if count < 0 {
                let required = -Int(count)
                guard required <= ModelTextBuffer.maximumBytes else { throw ModelTextBuffer.Failure.limitExceeded }
                storage = [CChar](repeating: 0, count: required)
                count = llama_token_to_piece(vocabulary, token, &storage, Int32(storage.count), 0, true)
            }
            guard count >= 0, count <= storage.count else { throw TranslationError.inferenceFailed }
            return storage.prefix(Int(count)).map(UInt8.init(bitPattern:))
        }

        private static func languageName(for code: String) -> String {
            if code == "system" {
                let systemCode = Locale.current.language.languageCode?.identifier ?? "en"
                return Locale.current.localizedString(forLanguageCode: systemCode) ?? "English"
            }
            return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }
}
