import AppKit

/// Finder may badge a protected installed bundle with a lock. In-app artwork should use the
/// original bundled asset while leaving the installer's filesystem protection intact.
enum AppIconArtwork {
    static let image: NSImage = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        if let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }()
}
