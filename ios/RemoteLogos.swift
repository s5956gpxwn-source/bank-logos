// RemoteLogos.swift — reference implementation (copy into the app, adapt names/style).
// Loads bank/store logos from public GitHub repos through jsDelivr, light/dark aware,
// cached on disk, downsampled to the size actually shown. No third-party dependencies.

import SwiftUI
import UIKit
import ImageIO

// MARK: - Source (one per repo)

struct LogoSource: Sendable, Hashable {
    let owner: String
    let repo: String
    let manifestFile: String

    static let banks  = LogoSource(owner: "s5956gpxwn-source", repo: "bank-logos",  manifestFile: "banks.json")
    // store-logos repo not created yet; same layout and manifest schema.
    static let stores = LogoSource(owner: "s5956gpxwn-source", repo: "store-logos", manifestFile: "stores.json")

    private var base: String { "https://cdn.jsdelivr.net/gh/\(owner)/\(repo)" }

    /// Branch URL: CDN refreshes it within ~12h. Always fetched bypassing the local cache.
    var manifestURL: URL { URL(string: "\(base)@main/\(manifestFile)")! }

    /// Tag URL (`vN` == manifest `version`): immutable, safe to cache forever.
    /// `folder` is "light", "dark" or "neutral".
    func imageURL(id: String, folder: String, version: Int) -> URL {
        URL(string: "\(base)@v\(version)/\(folder)/png/\(id).png")!
    }
}

/// `.brand` = full-color logo, light/dark picked from the color scheme.
/// `.neutral` = single white (#FFFFFF) version. Dark backgrounds ONLY (invisible on light ones).
enum LogoStyle: String, Sendable {
    case brand, neutral
}

// MARK: - Manifest

struct LogoManifest: Decodable, Sendable {
    let version: Int
    let items: [LogoItem]
}

struct LogoItem: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String              // brand color, light mode
    let colorDark: String          // color the logo uses in dark mode (may be #FFFFFF)
    let secondaryColor: String?
    let secondaryColorDark: String?
}

@MainActor
final class LogoStore: ObservableObject {
    static let shared = LogoStore()
    @Published private(set) var manifests: [LogoSource: LogoManifest] = [:]

    func manifest(for source: LogoSource) -> LogoManifest? { manifests[source] }

    func item(_ id: String, in source: LogoSource) -> LogoItem? {
        manifests[source]?.items.first { $0.id == id }
    }

    /// Call once at launch (and e.g. when the app returns to foreground) per source.
    func refresh(_ source: LogoSource) async {
        let file = Self.cacheFile(for: source)
        if manifests[source] == nil, let data = try? Data(contentsOf: file), let m = Self.decode(data) {
            manifests[source] = m                                   // last known copy, works offline
        }
        let request = URLRequest(url: source.manifestURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData, // branch files carry max-age=7d
                                 timeoutInterval: 15)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = Self.decode(data) else { return }
        manifests[source] = fresh
        try? data.write(to: file, options: .atomic)
    }

    private static func decode(_ data: Data) -> LogoManifest? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(LogoManifest.self, from: data)
    }

    private static func cacheFile(for source: LogoSource) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteLogos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(source.repo)-\(source.manifestFile)")
    }
}

// MARK: - Image loading

actor LogoImageLoader {
    static let shared = LogoImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteLogos", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 100 * 1024 * 1024, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad   // URLs are versioned, never stale
        return URLSession(configuration: config)
    }()

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))"
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }

        let session = self.session
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    /// PNGs are 1200px; decoding them full size costs ~5.7 MB each. Decode only what is shown.
    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - View

struct RemoteLogo: View {
    let id: String
    var source: LogoSource = .banks
    var style: LogoStyle = .brand
    var size: CGFloat = 40
    /// Only for `.neutral`: renders the logo as a template image in this color
    /// (two-tone logos keep their inner contrast via alpha). nil = the shipped white.
    var tint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var store = LogoStore.shared
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                if style == .neutral, let tint {
                    Image(uiImage: image).renderingMode(.template).resizable().scaledToFit().foregroundStyle(tint)
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(store.item(id, in: source)?.name ?? id)
        .task(id: loadKey) { await load() }
    }

    private var isDark: Bool { colorScheme == .dark }
    private var folder: String { style == .neutral ? "neutral" : (isDark ? "dark" : "light") }
    private var loadKey: String { "\(id)|\(folder)|\(store.manifest(for: source)?.version ?? 0)" }

    private func load() async {
        guard let version = store.manifest(for: source)?.version else { return }
        let url = source.imageURL(id: id, folder: folder, version: version)
        if let loaded = await LogoImageLoader.shared.image(for: url, maxPixel: size * displayScale) {
            image = loaded
        }
    }

    private var placeholder: some View {
        let item = store.item(id, in: source)
        let tint = style == .neutral
            ? (self.tint ?? .white)
            : Color(logoHex: (isDark ? item?.colorDark : item?.color) ?? "#8E8E93")
        return Circle()
            .fill(tint.opacity(0.18))
            .overlay(Text(String((item?.name ?? id).prefix(1)))
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint))
    }
}

extension Color {
    /// "#RRGGBB" → Color. Rename or drop if the app already has a hex initializer.
    init(logoHex hex: String) {
        let v = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8E8E93
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
