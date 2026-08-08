import CoreMediaIO
import Foundation

let providerSource = CameraExtensionProviderSource()
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
