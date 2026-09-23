//
//  CoverView.swift
//  PodcastAI
//
//  Das Cover eines Themen-Updates.
//
//  Zwei Schichten. Oben das Bild von Image Playground: abstrakt, aus den
//  Themen des Updates, einmal je Update erzeugt und als Datei abgelegt
//  (`TopicCoverArt`, Ablage und Erzeugung im Paket). Darunter das
//  Layoutcover: Farbverlauf, Titel und Datum. Es steht, solange kein Bild
//  da ist, und auf Geräten ohne Image Playground immer. Deshalb muss es für
//  sich gut aussehen, nicht nur als Platzhalter.
//
//  Der Titel im Layout bricht nie mitten im Wort. Früher stand dort
//  „Datensch utz“: SwiftUI trennt ein Wort, das nicht in die Zeile passt,
//  zwischen zwei Buchstaben. Die Schriftgröße richtet sich deshalb nach dem
//  breitesten Wort (`CoverTitleFit`), erst danach darf SwiftUI verkleinern.
//

import SwiftUI
import PodcastAIKit
#if canImport(ImagePlayground)
import ImagePlayground
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct CoverView: View {

    let cover: CoverAsset
    var size: CGFloat = 88
    /// Das Bild von Image Playground. Ohne Bild zeigt das Cover sein Layout.
    var image: CGImage? = nil
    /// Entsteht gerade ein neues Bild?
    var isGenerating = false

    private var cornerRadius: CGFloat { max(6, size * 0.12) }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                CoverLayout(cover: cover, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            // Eine feine Kante, damit helle Bilder nicht im Hintergrund zerfließen.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
        }
        .overlay {
            if isGenerating {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.black.opacity(0.3))
                    ProgressView()
                        .controlSize(size < 80 ? .small : .regular)
                        .tint(.white)
                }
            }
        }
        // Pflicht, nicht Kür: `altText` ist im Modell nicht optional,
        // weil ein Cover ohne Beschreibung für VoiceOver ein leeres
        // Bild ist.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cover.altText)
        .accessibilityValue(isGenerating ? String(localized: "Neues Cover entsteht") : "")
        .accessibilityAddTraits(.isImage)
    }
}

/// Das Layoutcover: Farbverlauf, Wellenform, Titel und Datum.
private struct CoverLayout: View {

    let cover: CoverAsset
    let size: CGFloat

    /// Unter dieser Größe ist Schrift nicht mehr lesbar. Dort zeigt das
    /// Cover nur Farbe und Zeichen, der Titel steht ohnehin daneben.
    private var showsText: Bool { size >= 80 }
    private var padding: CGFloat { size * 0.1 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(CoverPalette.mesh(for: cover.paletteIndex))

            if showsText {
                // Die Wellenform groß und angeschnitten, als Motiv im Hintergrund.
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(.white.opacity(0.18))
                    .offset(x: size * 0.22, y: -size * 0.14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: size * 0.025) {
                    Text(cover.title)
                        .font(.system(size: titleSize, weight: .bold, design: .rounded))
                        .lineLimit(3)
                        // Verkleinern ist erst nach `CoverTitleFit` sicher:
                        // kleiner werden bricht kein Wort.
                        .minimumScaleFactor(0.6)
                    if let subtitle = cover.subtitle {
                        Text(subtitle)
                            .font(.system(size: size * 0.085, weight: .semibold))
                            .opacity(0.85)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: size * 0.01, y: size * 0.005)
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var titleSize: CGFloat {
        CoverTitleFit.fontSize(for: cover.title, width: size - 2 * padding, preferred: size * 0.16)
    }
}

/// Die Farben der Layoutcover. Der Index kommt deterministisch aus dem
/// Titel, derselbe Feed wechselt nicht bei jeder Ausgabe die Farbe.
enum CoverPalette {

    /// So viele wie `NativeCoverRenderer.paletteCount`.
    static let colors: [[Color]] = [
        [.indigo, .purple, .pink],
        [.teal, .blue, .indigo],
        [.orange, .pink, .purple],
        [.mint, .teal, .blue],
        [.orange, .red, .pink],
        [.cyan, .blue, .purple],
        [.green, .teal, .indigo],
        [.pink, .purple, .indigo],
    ]

    /// Ein weicher Verlauf über drei Farben. Die Mitte verschiebt sich je
    /// Farbe ein wenig, damit nicht jedes Cover gleich fließt.
    static func mesh(for index: Int) -> MeshGradient {
        let slot = abs(index) % colors.count
        let c = colors[slot]
        let shift = Float(slot % 3 - 1) * 0.12
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + shift, 0.5 - shift], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                c[0], c[0], c[1],
                c[0], c[1], c[2],
                c[1], c[2], c[2],
            ]
        )
    }
}

/// Die Schriftgröße, bei der jedes Wort des Titels in eine Zeile passt.
///
/// `lineBreakStrategy` gibt es nur in UIKit und AppKit, und auch dort
/// verhindert sie nicht, dass ein zu langes Wort zerteilt wird. Gemessen
/// wird deshalb das breiteste Wort in der Schrift des Covers.
enum CoverTitleFit {

    static func fontSize(for title: String, width: CGFloat, preferred: CGFloat) -> CGFloat {
        guard width > 0, preferred > 0 else { return preferred }
        // Nach einem Bindestrich darf die Zeile umbrechen, also zählt das Stück.
        let words = title.split { $0.isWhitespace || $0 == "-" || $0 == "/" }
        let widest = words.map { measuredWidth(of: String($0), size: preferred) }.max() ?? 0
        // Etwas Luft, weil SwiftUI nicht auf den Punkt genau so setzt.
        let available = width * 0.96
        guard widest > available else { return preferred }
        return max(6, preferred * available / widest)
    }

    private static func measuredWidth(of word: String, size: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        var font = UIFont.systemFont(ofSize: size, weight: .bold)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: rounded, size: size)
        }
        #elseif canImport(AppKit)
        var font = NSFont.systemFont(ofSize: size, weight: .bold)
        if let rounded = font.fontDescriptor.withDesign(.rounded),
           let roundedFont = NSFont(descriptor: rounded, size: size) {
            font = roundedFont
        }
        #endif
        return ceil((word as NSString).size(withAttributes: [.font: font]).width)
    }
}

// MARK: - Cover eines Themen-Updates

/// Das Cover eines Themen-Updates: das Bild, sobald es da ist, sonst das
/// Layout. Wer es zeigt, stößt das Bild an, falls es fehlt oder zu alten
/// Themen gehört.
struct FeedCoverView: View {

    let feed: SmartPodcastFeed
    var edition: PersonalEpisode? = nil
    var size: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        CoverView(
            cover: edition.flatMap { model.cover(for: $0) } ?? NativeCoverRenderer().makeCover(for: feed),
            size: size,
            image: model.coverArt.image(for: feed.id),
            isGenerating: model.coverArt.isGenerating(feed.id)
        )
        .task(id: model.coverRecipe(for: feed)) {
            await model.coverArt.prepare(model.coverRecipe(for: feed))
        }
    }
}

/// Der Systemdialog von Image Playground, falls die App selbst kein Bild
/// erzeugen darf. Nur Apple-Stile, keine Gesichter aus der Mediathek.
struct CoverPlaygroundSheet: ViewModifier {

    @Binding var isPresented: Bool
    let recipe: TopicCoverRecipe?
    let onImage: (URL) -> Void

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
        content
            .imagePlaygroundSheet(
                isPresented: $isPresented,
                concepts: (recipe?.attempts.first ?? []).map { ImagePlaygroundConcept.text($0) },
                onCompletion: onImage
            )
            .imagePlaygroundGenerationStyle(.illustration, in: [.illustration])
            .modifier(PlaygroundOptions())
        #else
        content
        #endif
    }

    #if canImport(ImagePlayground)
    private struct PlaygroundOptions: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26.4, macOS 26.4, *) {
                var options = ImagePlaygroundOptions()
                options.personalization = .disabled
                return AnyView(content.imagePlaygroundOptions(options))
            } else {
                return AnyView(content)
            }
        }
    }
    #endif
}

extension View {
    func coverPlaygroundSheet(
        isPresented: Binding<Bool>, recipe: TopicCoverRecipe?, onImage: @escaping (URL) -> Void
    ) -> some View {
        modifier(CoverPlaygroundSheet(isPresented: isPresented, recipe: recipe, onImage: onImage))
    }
}

// MARK: - Bilder der Themen-Updates

/// Hält die Bildcover der Themen-Updates und erzeugt fehlende.
///
/// Erzeugt wird eins nach dem anderen und nur, während die App sichtbar
/// ist: `ImageCreator` verweigert die Arbeit im Hintergrund. Angestoßen
/// wird deshalb aus der Oberfläche, wenn ein Cover erscheint, nie aus der
/// Hintergrundaktualisierung. Ein Themenstand, der schon scheiterte, wird
/// in diesem Prozess nicht von selbst erneut versucht.
@MainActor
@Observable
final class TopicCoverArt {

    enum Outcome: Equatable { case created, needsDialog, unavailable, failed, postponed }

    /// Geladene oder frisch erzeugte Bilder, je Update.
    private(set) var covers: [SmartFeedID: TopicCover] = [:]
    /// Updates, deren Bild gerade entsteht.
    private(set) var generating: Set<SmartFeedID> = []
    /// Wie Bilder entstehen können. Steht nach dem ersten Versuch fest.
    private(set) var availability: TopicCoverGenerator.Availability = .unknown

    /// Nach jedem neuen Bild, damit der Sperrbildschirm nachzieht.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let store = TopicCoverStore.standard
    @ObservationIgnored private var loads: [SmartFeedID: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempted: [SmartFeedID: String] = [:]
    @ObservationIgnored private var pending: [TopicCoverRecipe] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var outcomes: [SmartFeedID: Outcome] = [:]
    @ObservationIgnored private var removed: Set<SmartFeedID> = []
    /// Layoutcover als Bild für den Sperrbildschirm, einmal je Layout.
    @ObservationIgnored private var renderedLayouts: [String: CGImage] = [:]

    func image(for feedID: SmartFeedID) -> CGImage? { covers[feedID]?.image }
    func isGenerating(_ feedID: SmartFeedID) -> Bool { generating.contains(feedID) }

    /// Kann jemand ein neues Cover anfordern? Ohne Image Playground bleibt
    /// das Layoutcover, und der Menüpunkt fehlt.
    var canCreate: Bool {
        availability == .available || TopicCoverGenerator.isDialogAvailable
    }

    /// Lädt das abgelegte Bild und erzeugt eins, wenn keins zu den Themen passt.
    func prepare(_ recipe: TopicCoverRecipe) async {
        await loadIfNeeded(recipe.feedID)
        if covers[recipe.feedID]?.stored.matches(recipe) == true { return }
        guard availability == .unknown || availability == .available,
              attempted[recipe.feedID] != recipe.digest else { return }
        enqueue(recipe)
    }

    /// Ein neues Bild auf Wunsch, auch wenn das alte noch passt.
    func regenerate(_ recipe: TopicCoverRecipe) async -> Outcome {
        await loadIfNeeded(recipe.feedID)
        switch availability {
        case .dialogOnly: return .needsDialog
        case .unavailable: return TopicCoverGenerator.isDialogAvailable ? .needsDialog : .unavailable
        case .unknown, .available: break
        }
        outcomes[recipe.feedID] = nil
        enqueue(recipe)
        while generating.contains(recipe.feedID), let worker { await worker.value }
        return outcomes[recipe.feedID] ?? .failed
    }

    /// Übernimmt das Bild aus dem Systemdialog.
    func adopt(fileAt url: URL, for recipe: TopicCoverRecipe) async -> Bool {
        // Die Datei des Dialogs ist kurzlebig: sofort lesen, dann ablegen.
        guard let image = TopicCoverStore.loadImage(at: url) else { return false }
        let store = self.store
        let cover = await Task.detached(priority: .userInitiated) { () -> TopicCover? in
            guard let stored = try? store.write(image, for: recipe),
                  let square = TopicCoverStore.loadImage(at: stored.url) else { return nil }
            return TopicCover(stored: stored, image: square)
        }.value
        guard let cover else { return false }
        covers[recipe.feedID] = cover
        attempted[recipe.feedID] = recipe.digest
        onChange?()
        return true
    }

    /// Ein gelöschtes Update nimmt sein Bild mit.
    func remove(_ feedID: SmartFeedID) {
        removed.insert(feedID)
        covers[feedID] = nil
        attempted[feedID] = nil
        loads[feedID] = nil
        pending.removeAll { $0.feedID == feedID }
        let store = self.store
        Task.detached(priority: .utility) { store.remove(feedID) }
    }

    /// Das Bild für den Sperrbildschirm: das erzeugte, sonst das Layout.
    func nowPlayingArtwork(for feed: SmartPodcastFeed, layout: CoverAsset) -> EpisodePlayer.FocusArtwork {
        if let cover = covers[feed.id] {
            let stamp = Int(cover.stored.createdAt.timeIntervalSince1970)
            return EpisodePlayer.FocusArtwork(key: "cover-\(feed.id.rawValue)-\(cover.stored.digest)-\(stamp)",
                                              image: cover.image)
        }
        // Über Siri gestartet ist das Bild vielleicht noch nicht geladen.
        if loads[feed.id] == nil {
            Task {
                await loadIfNeeded(feed.id)
                if covers[feed.id] != nil { onChange?() }
            }
        }
        let key = "layout-\(layout.id)-\(layout.paletteIndex)-\(layout.title)-\(layout.subtitle ?? "")"
        if let rendered = renderedLayouts[key] {
            return EpisodePlayer.FocusArtwork(key: key, image: rendered)
        }
        let renderer = ImageRenderer(content: CoverView(cover: layout, size: 600))
        renderer.scale = 1
        let image = renderer.cgImage
        if let image { renderedLayouts[key] = image }
        return EpisodePlayer.FocusArtwork(key: key, image: image)
    }

    // MARK: Laden und Erzeugen

    private func loadIfNeeded(_ feedID: SmartFeedID) async {
        if let load = loads[feedID] {
            await load.value
            return
        }
        let store = self.store
        let load = Task {
            let found = await Task.detached(priority: .utility) { () -> TopicCover? in
                guard let stored = store.stored(for: feedID),
                      let image = TopicCoverStore.loadImage(at: stored.url) else { return nil }
                return TopicCover(stored: stored, image: image)
            }.value
            if let found, covers[feedID] == nil, !removed.contains(feedID) { covers[feedID] = found }
        }
        loads[feedID] = load
        await load.value
    }

    private func enqueue(_ recipe: TopicCoverRecipe) {
        guard !generating.contains(recipe.feedID) else { return }
        removed.remove(recipe.feedID)
        generating.insert(recipe.feedID)
        attempted[recipe.feedID] = recipe.digest
        pending.append(recipe)
        if worker == nil {
            worker = Task { await drain() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let recipe = pending.removeFirst()
            outcomes[recipe.feedID] = await generate(recipe)
            generating.remove(recipe.feedID)
        }
        worker = nil
    }

    private func generate(_ recipe: TopicCoverRecipe) async -> Outcome {
        let store = self.store
        do {
            let cover = try await Task.detached(priority: .userInitiated) {
                try await store.generate(for: recipe)
            }.value
            availability = .available
            // Während das Bild entstand, wurde das Update gelöscht.
            guard !removed.contains(recipe.feedID) else {
                Task.detached(priority: .utility) { store.remove(recipe.feedID) }
                return .failed
            }
            covers[recipe.feedID] = cover
            onChange?()
            return .created
        } catch TopicCoverGenerator.Failure.unavailable {
            let dialog = TopicCoverGenerator.isDialogAvailable
            availability = dialog ? .dialogOnly : .unavailable
            // Was noch wartet, entsteht auf diesem Weg auch nicht.
            let outcome: Outcome = dialog ? .needsDialog : .unavailable
            for waiting in pending {
                generating.remove(waiting.feedID)
                outcomes[waiting.feedID] = outcome
            }
            pending.removeAll()
            return outcome
        } catch TopicCoverGenerator.Failure.notInForeground {
            // Beim nächsten Erscheinen noch einmal.
            attempted[recipe.feedID] = nil
            return .postponed
        } catch TopicCoverGenerator.Failure.cancelled {
            attempted[recipe.feedID] = nil
            return .postponed
        } catch {
            return .failed
        }
    }
}

// MARK: - Modell

extension AppModel {

    /// Die Themen eines Updates als Begriffe, in der Reihenfolge des Updates.
    func coverRecipe(for feed: SmartPodcastFeed) -> TopicCoverRecipe {
        let labels = feed.topicIDs.compactMap { id in
            profile.interests.first { $0.id == id }?.label
        }
        return TopicCoverRecipe(feed: feed, topics: labels)
    }

    /// Die Ausgabe eines Themen-Updates, die dieser Plan abspielt.
    ///
    /// Der Plan kennt sein Update nicht. Er entsteht aber Stelle für Stelle
    /// aus der Ausgabe, über den Knopf wie über Siri, und daran ist sie zu
    /// erkennen.
    func edition(playing plan: ValidatedPlaybackPlan) -> PersonalEpisode? {
        guard plan.route == .smartFeedEpisode else { return nil }
        for feedEditions in editions.values {
            for edition in feedEditions
            where edition.title == plan.requestSummary && edition.segments.count == plan.segments.count {
                let same = zip(edition.segments, plan.segments).allSatisfy { part, planned in
                    part.mediaVersionID == planned.mediaVersionID && part.playbackRange == planned.range
                }
                if same { return edition }
            }
        }
        return nil
    }

    /// Das Cover des Podcasts, aus dem eine Stelle stammt.
    func podcastArtworkURL(for segment: PlanSegment) -> URL? {
        sources.first { $0.id == segment.sourceID }?.artworkURL
    }

    /// Was der Sperrbildschirm zu einem Fokus-Plan zeigt: das Cover des
    /// Themen-Updates, sonst das Cover des Podcasts der laufenden Stelle.
    func focusArtwork(for plan: ValidatedPlaybackPlan, segment: PlanSegment) -> EpisodePlayer.FocusArtwork? {
        if let edition = edition(playing: plan),
           let feed = smartFeeds.first(where: { $0.id == edition.feedID }) {
            let layout = cover(for: edition) ?? NativeCoverRenderer().makeCover(for: feed)
            return coverArt.nowPlayingArtwork(for: feed, layout: layout)
        }
        guard let url = podcastArtworkURL(for: segment) else { return nil }
        return EpisodePlayer.FocusArtwork(key: url.absoluteString, url: url)
    }
}
