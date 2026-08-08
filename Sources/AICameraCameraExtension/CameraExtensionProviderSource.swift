import CoreMediaIO
import Foundation

final class CameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let deviceSource: CameraExtensionDeviceSource

    override init() {
        deviceSource = CameraExtensionDeviceSource()
        super.init()
        provider = CMIOExtensionProvider(
            source: self,
            clientQueue: DispatchQueue(
                label: "ai.kortexa.aicamera.camera-extension.clients",
                qos: .userInteractive
            )
        )
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Unable to publish the AI Camera device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        // CoreMediaIO validates and transports media for accepted clients.
    }

    func disconnect(from client: CMIOExtensionClient) {
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerName, .providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            result.name = AICameraVirtualCamera.localizedName
        }
        if properties.contains(.providerManufacturer) {
            result.manufacturer = AICameraVirtualCamera.manufacturer
        }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // This provider has no writable provider-level properties.
    }
}
