import AppKit

final class IconCatalog {
    static let shared = IconCatalog()
    
    private let cacheLock = NSLock()
    private var cache: [String: NSImage] = [:]
    private let bundle = Bundle.main
    
    private init() {}
    
    func image(named name: String, resizedTo size: NSSize? = nil, template: Bool = false) -> NSImage? {
        let key = cacheKey(name: name, size: size, template: template)

        if let cached = readCache(key: key) {
            return cached.copy() as? NSImage
        }

        guard let resourcePath = bundle.resourcePath else { return nil }
        let iconPath = (resourcePath as NSString).appendingPathComponent(name)
        guard let baseImage = NSImage(contentsOfFile: iconPath) else { return nil }

        let image = baseImage.copy() as? NSImage ?? baseImage
        if let size {
            image.size = size
        }
        image.isTemplate = template

        writeCache(key: key, image: image)
        return image.copy() as? NSImage ?? image
    }

    private func readCache(key: String) -> NSImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private func writeCache(key: String, image: NSImage) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = image
    }

    private func cacheKey(name: String, size: NSSize?, template: Bool) -> String {
        if let size {
            return "\(name)-\(Int(size.width))x\(Int(size.height))-\(template)"
        }
        return "\(name)-original-\(template)"
    }
}
