import Foundation

/// The normal desktop product supports public OpenAI audio and local media processing.
/// Preserve older endpoint definitions for profile transfer, but do not activate them.
public enum SupportedConfigurationPolicy {
    public static func isPublicRealtime(_ endpoint: EndpointConfiguration) -> Bool {
        endpoint.adapter == .openAIRealtime && hasPublicOpenAIBaseURL(endpoint)
    }

    public static func isPublicTranscription(_ endpoint: EndpointConfiguration) -> Bool {
        endpoint.adapter == .openAITranscription && hasPublicOpenAIBaseURL(endpoint)
    }

    private static func hasPublicOpenAIBaseURL(_ endpoint: EndpointConfiguration) -> Bool {
        let url = endpoint.baseURL
        return url.scheme == "https" && url.host == "api.openai.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && ["", "/", "/v1", "/v1/"].contains(url.path)
            && endpoint.path == nil
    }

    @discardableResult
    public static func disableUnsupportedRoutes(in profile: inout AICameraConfiguration) -> Bool {
        var changed = false
        for index in profile.pipeline.videoStages.indices {
            let stage = profile.pipeline.videoStages[index]
            let local = stage.kind == .handGesture
                || (stage.kind == .objectDetection && stage.options["provider"]?.stringValue == "builtin")
            if stage.enabled && !local {
                profile.pipeline.videoStages[index].enabled = false
                changed = true
            }
        }
        let conversation = profile.pipeline.conversation
        if conversation.enabled {
            let endpoint = profile.endpoints.first { $0.id == conversation.realtimeEndpointID }
            if !conversation.realtimeEnabled || endpoint.map(isPublicRealtime) != true {
                profile.pipeline.conversation.enabled = false
                changed = true
            }
        }
        if conversation.transcriptionEnabled, conversation.transcriptionProvider == .openAI {
            let endpoint = profile.endpoints.first { $0.id == conversation.transcriptionEndpointID }
            if endpoint.map(isPublicTranscription) != true {
                // A saved credential does not authorize moving microphone audio to another service.
                // Keep independent Realtime translation and the old metadata unchanged.
                profile.pipeline.conversation.transcriptionEnabled = false
                changed = true
            }
        }
        return changed
    }
}
