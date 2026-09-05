import Foundation

/// The normal desktop product supports public Realtime and local video processing.
/// Preserve older endpoint definitions for profile transfer, but do not activate them.
public enum SupportedConfigurationPolicy {
    public static func isPublicRealtime(_ endpoint: EndpointConfiguration) -> Bool {
        let url = endpoint.baseURL
        return endpoint.adapter == .openAIRealtime
            && url.scheme == "https" && url.host == "api.openai.com"
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
        return changed
    }
}
