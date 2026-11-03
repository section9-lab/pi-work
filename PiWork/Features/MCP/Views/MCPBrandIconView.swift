import AppKit
import SwiftUI

struct MCPBrandIconView: View {
    let name: String
    var urls: [URL] = []
    var size: CGFloat = 40
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(image == nil ? Color.accentColor.opacity(0.09) : Color.white)
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(size * 0.10)
            } else {
                Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased())
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.23).strokeBorder(Color.primary.opacity(0.07)))
        .task(id: urls) {
            image = nil
            for url in urls {
                if let loaded = await MCPBrandImageStore.shared.image(for: url) {
                    guard !Task.isCancelled else { return }
                    image = loaded
                    return
                }
                guard !Task.isCancelled else { return }
            }
        }
        .accessibilityHidden(true)
    }

    static func urls(for server: MCPServer, preset: MCPMarketPreset?) -> [URL] {
        if let preset, !preset.iconURLs.isEmpty { return preset.iconURLs }
        guard let object = try? JSONSerialization.jsonObject(with: Data(server.configurationJSON.utf8)) as? [String: Any],
              let address = object["url"] as? String,
              var parts = URLComponents(string: address) else { return [] }
        parts.path = "/favicon.ico"
        parts.query = nil
        parts.fragment = nil
        return parts.string.flatMap(MCPMarketURL.publicHTTPS).map { [$0] } ?? []
    }
}

protocol MCPArtworkLoading: Sendable {
    func data(for url: URL) async -> Data?
}

@MainActor
final class MCPBrandImageStore {
    static let shared = MCPBrandImageStore()
    private let cache = NSCache<NSURL, NSImage>()
    private var tasks: [URL: Task<Data?, Never>] = [:]
    private var misses: [URL: Date] = [:]
    private let downloader: any MCPArtworkLoading

    init(downloader: (any MCPArtworkLoading)? = nil) {
        self.downloader = downloader ?? MCPArtworkDownloader()
        cache.countLimit = 200
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func image(for url: URL) async -> NSImage? {
        guard MCPMarketURL.publicHTTPS(url.absoluteString) != nil else { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let miss = misses[url], Date().timeIntervalSince(miss) < 300 { return nil }
        let task: Task<Data?, Never>
        if let existing = tasks[url] { task = existing }
        else {
            let downloader = downloader
            task = Task { await downloader.data(for: url) }
            tasks[url] = task
        }
        let data = await task.value
        tasks[url] = nil
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let data, let source = NSImage(data: data), source.isValid,
              source.size.width > 0, source.size.height > 0,
              source.size.width <= 8192, source.size.height <= 8192,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            if misses.count > 512 { misses = [:] }
            misses[url] = Date()
            return nil
        }
        // Rasterize SVG and bitmap originals once, at a bounded display size.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = min(96 / source.size.width, 96 / source.size.height)
        let width = source.size.width * scale
        let height = source.size.height * scale
        source.draw(in: NSRect(x: (96 - width) / 2, y: (96 - height) / 2, width: width, height: height),
                    from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 96, height: 96))
        image.addRepresentation(bitmap)
        cache.setObject(image, forKey: url as NSURL, cost: 96 * 96 * 4)
        return image
    }
}

private final class MCPArtworkRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { MCPMarketURL.publicHTTPS($0.absoluteString) } == nil ? nil : request)
    }
}

private actor MCPArtworkDownloader: MCPArtworkLoading {
    private let session: URLSession
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 24 * 1024 * 1024)
        session = URLSession(configuration: configuration, delegate: MCPArtworkRedirects(), delegateQueue: nil)
    }

    func data(for url: URL) async -> Data? {
        if active >= 4 { await withCheckedContinuation { waiters.append($0) } }
        else { active += 1 }
        defer {
            if waiters.isEmpty { active -= 1 }
            else { waiters.removeFirst().resume() }
        }
        do {
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= 2 * 1024 * 1024 else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 2 * 1024 * 1024 { return nil }
            }
            if let svg = String(data: data, encoding: .utf8), svg.contains("<svg") {
                let lower = svg.lowercased()
                // Native SVG only: reject active content and external references.
                guard !["<script", "<!doctype", "<!entity", "<foreignobject"].contains(where: lower.contains) else { return nil }
                for pattern in [#"href\s*=\s*[\"']([^\"']+)[\"']"#, #"url\(([^)]+)\)"#] {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
                    let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
                    for match in regex.matches(in: lower, range: range) {
                        guard let valueRange = Range(match.range(at: 1), in: lower),
                              lower[valueRange].trimmingCharacters(in: .whitespacesAndNewlines
                                .union(CharacterSet(charactersIn: "\"'"))).hasPrefix("#") else { return nil }
                    }
                }
            }
            return data
        } catch { return nil }
    }
}
