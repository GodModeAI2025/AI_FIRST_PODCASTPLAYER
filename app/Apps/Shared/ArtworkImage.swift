//
//  ArtworkImage.swift
//  PodcastAI
//
//  Cover in Listen, verkleinert und im Speicher gehalten.
//
//  `AsyncImage` dekodiert ein Cover in voller Größe. Podcastcover haben oft
//  3000 × 3000 Pixel, also rund 36 MB je Bild, auch für ein Vorschaubild
//  von 44 Punkten. Beim Scrollen durch „Meine Podcasts“ oder eine lange
//  Folgenliste dekodierte die App sie immer wieder neu.
//
//  Hier lädt `URLSession.shared` die Daten wie bisher über den gemeinsamen
//  `URLCache`. ImageIO verkleinert beim Dekodieren gleich auf die Pixel,
//  die die Ansicht braucht, außerhalb des Hauptthreads. Die kleinen Bilder
//  bleiben in einem `NSCache`, das System leert ihn bei Speicherdruck.
//

import SwiftUI
import ImageIO

/// Lädt und verkleinert Cover. Gleiche Anfragen zur selben Zeit laden einmal.
actor ArtworkThumbnails {

    static let shared = ArtworkThumbnails()

    struct Key: Hashable, Sendable {
        let url: URL
        let pixels: Int
        /// Steigt nach „Neu laden“ einer Quelle (`ArtworkRefresh`).
        let revision: Int
    }

    /// `NSCache` ist threadsicher, nur nicht als `Sendable` markiert.
    private nonisolated(unsafe) static let memory: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private var loading: [Key: Task<CGImage?, Never>] = [:]

    /// Schon verkleinert im Speicher? Ohne Warten, für den ersten Frame.
    nonisolated static func cached(_ key: Key) -> CGImage? {
        memory.object(forKey: name(key))?.image
    }

    func image(for key: Key) async -> CGImage? {
        if let cached = Self.cached(key) { return cached }
        if let running = loading[key] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: key.url)) else { return nil }
            return Self.downsample(data, maxPixels: key.pixels)
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image {
            Self.memory.setObject(CGImageBox(image), forKey: Self.name(key),
                                  cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// Dekodiert nur so groß wie nötig.
    nonisolated static func downsample(_ data: Data, maxPixels: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private nonisolated static func name(_ key: Key) -> NSString {
        "\(key.revision)|\(key.pixels)|\(key.url.absoluteString)" as NSString
    }
}

/// Hülle für `NSCache`, der nur Objekte nimmt.
final class CGImageBox: Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Ein Cover in fester Größe. Solange es lädt oder wenn es fehlt, steht
/// `placeholder` da.
struct ArtworkImage<Placeholder: View>: View {
    let url: URL?
    let side: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: ArtworkThumbnails.Key, image: CGImage)?

    private var key: ArtworkThumbnails.Key? {
        url.map {
            // In Stufen von 32 Pixeln, damit leicht andere Größen dasselbe Bild nutzen.
            let pixels = Int((side * displayScale / 32).rounded(.up)) * 32
            return ArtworkThumbnails.Key(url: $0, pixels: pixels, revision: ArtworkRefresh.shared.revision(for: $0))
        }
    }

    var body: some View {
        let key = key
        let image = key.flatMap { key in loaded?.key == key ? loaded?.image : ArtworkThumbnails.cached(key) }
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: key) {
            guard let key, image == nil, let fresh = await ArtworkThumbnails.shared.image(for: key) else { return }
            loaded = (key, fresh)
        }
    }
}
