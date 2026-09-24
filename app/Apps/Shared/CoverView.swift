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
//  breitesten Stück (`CoverTitleFit`), erst danach darf SwiftUI verkleinern.
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
/// wird deshalb das breiteste Stück in der Schrift des Covers.
enum CoverTitleFit {

    static func fontSize(for title: String, width: CGFloat, preferred: CGFloat) -> CGFloat {
        guard width > 0, preferred > 0 else { return preferred }
        let widest = pieces(of: title).map { measuredWidth(of: $0, size: preferred) }.max() ?? 0
        // Etwas Luft, weil SwiftUI nicht auf den Punkt genau so setzt.
        let available = width * 0.96
        guard widest > available else { return preferred }
        return max(6, preferred * available / widest)
    }

    /// Was zusammen in einer Zeile stehen muss. Nach einem Bindestrich oder
    /// Schrägstrich darf die Zeile umbrechen, davor nicht. Das Zeichen
    /// gehört deshalb zum Stück davor: „Datenschutz-“ und „Update“. Ohne
    /// den Strich gemessen passte „Datenschutz“, mit ihm nicht mehr, und
    /// SwiftUI brach doch wieder mitten im Wort.
    static func pieces(of title: String) -> [String] {
        var pieces: [String] = []
        for word in title.split(whereSeparator: \.isWhitespace) {
            var piece = ""
            for character in word {
                piece.append(character)
                if character == "-" || character == "/" {
                    pieces.append(piece)
                    piece = ""
                }
            }
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces
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
/// Tags gehört.
///
/// Mit `edition` ist es das Cover dieser Ausgabe, wie das einer Folge:
/// ihr eigenes Bild, bis dahin das des Updates, sonst ihr Layout.
struct FeedCoverView: View {

    let feed: SmartPodcastFeed
    var edition: PersonalEpisode? = nil
    var size: CGFloat
    @Environment(AppModel.self) private var model

    private var editionKey: TopicCoverKey? {
        edition.map { TopicCoverKey(feedID: feed.id, editionID: $0.id) }
    }

    var body: some View {
        let feedKey = TopicCoverKey(feedID: feed.id)
        let image = editionKey.flatMap { model.coverArt.image(for: $0) } ?? model.coverArt.image(for: feedKey)
        CoverView(
            cover: edition.flatMap { model.cover(for: $0) } ?? NativeCoverRenderer().makeCover(for: feed),
            size: size,
            image: image,
            isGenerating: model.coverArt.isGenerating(editionKey ?? feedKey)
        )
        .task(id: model.coverRecipe(for: feed)) {
            await model.coverArt.prepare(model.coverRecipe(for: feed))
        }
        .task(id: edition?.id) {
            guard let edition else { return }
            await model.prepareCover(for: edition)
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
            // Ohne diese Sperre böte der Dialog Gesichter aus der Mediathek
            // an, etwa wenn ein Thema ein Name ist.
            var options = ImagePlaygroundOptions()
            options.personalization = .disabled
            return content.imagePlaygroundOptions(options)
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

/// Hält die Bildcover der Themen-Updates und ihrer Ausgaben und erzeugt
/// fehlende.
///
/// Erzeugt wird eins nach dem anderen und nur, während die App sichtbar
/// ist: `ImageCreator` verweigert die Arbeit im Hintergrund. Angestoßen
/// wird deshalb aus der Oberfläche, wenn ein Cover erscheint, nach einer
/// neuen Ausgabe im Vordergrund und beim Wechsel in den Vordergrund, nie
/// aus der Hintergrundaktualisierung. Ein Stand, der schon scheiterte,
/// wird in diesem Prozess nicht von selbst erneut versucht.
@MainActor
@Observable
final class TopicCoverArt {

    enum Outcome: Equatable { case created, needsDialog, unavailable, failed, postponed }

    /// Geladene oder frisch erzeugte Bilder, je Update und je Ausgabe.
    private(set) var covers: [TopicCoverKey: TopicCover] = [:]
    /// Bilder, die gerade entstehen.
    private(set) var generating: Set<TopicCoverKey> = []
    /// Wie Bilder entstehen können. Steht nach dem ersten Versuch fest.
    private(set) var availability: TopicCoverGenerator.Availability = .unknown

    /// Nach jedem neuen Bild, damit der Sperrbildschirm nachzieht.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let store = TopicCoverStore.standard
    @ObservationIgnored private var loads: [TopicCoverKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempted: [TopicCoverKey: String] = [:]
    @ObservationIgnored private var pending: [TopicCoverRecipe] = []
    /// Neue Tags eines Updates, dessen Bild gerade entsteht. Kommen danach dran.
    @ObservationIgnored private var followUps: [TopicCoverKey: TopicCoverRecipe] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var outcomes: [TopicCoverKey: Outcome] = [:]
    @ObservationIgnored private var removed: Set<TopicCoverKey> = []
    /// Rezepte, die gerade berechnet werden.
    @ObservationIgnored private var preparing: Set<TopicCoverKey> = []
    /// Layoutcover als Bild für den Sperrbildschirm, einmal je Layout.
    @ObservationIgnored private var renderedLayouts: [String: CGImage] = [:]

    func image(for feedID: SmartFeedID) -> CGImage? { covers[TopicCoverKey(feedID: feedID)]?.image }
    func image(for key: TopicCoverKey) -> CGImage? { covers[key]?.image }
    func isGenerating(_ feedID: SmartFeedID) -> Bool { generating.contains(TopicCoverKey(feedID: feedID)) }
    func isGenerating(_ key: TopicCoverKey) -> Bool { generating.contains(key) }

    /// Kann jemand ein neues Cover anfordern? Ohne Image Playground bleibt
    /// das Layoutcover, und der Menüpunkt fehlt.
    var canCreate: Bool {
        availability == .available || TopicCoverGenerator.isDialogAvailable
    }

    /// Kann die App überhaupt versuchen, ein Bild selbst zu erzeugen?
    var mayGenerate: Bool { availability == .unknown || availability == .available }

    /// Lädt das abgelegte Bild und erzeugt eins, wenn keins passt.
    func prepare(_ recipe: TopicCoverRecipe) async {
        let key = recipe.key
        await loadIfNeeded(key)
        if covers[key]?.stored.matches(recipe) == true { return }
        guard mayGenerate, attempted[key] != recipe.digest, !removed.contains(key) else { return }
        enqueue(recipe)
    }

    /// Hat dieser Besitzer schon ein Bild, geladen oder abgelegt? Für eine
    /// Ausgabe genügt das: Sie ändert sich nicht, ihr Bild bleibt gültig.
    func hasCover(_ key: TopicCoverKey) async -> Bool {
        await loadIfNeeded(key)
        return covers[key] != nil
    }

    /// Wurde für diesen Besitzer in diesem Prozess schon ein Versuch
    /// gemacht? Dann lohnt es nicht, das Rezept noch einmal zu berechnen.
    func wasAttempted(_ key: TopicCoverKey) -> Bool { attempted[key] != nil || generating.contains(key) }

    /// Merkt sich, dass das Rezept für diesen Besitzer gerade entsteht.
    /// `false`, wenn das schon läuft.
    func beginPreparing(_ key: TopicCoverKey) -> Bool { preparing.insert(key).inserted }
    func endPreparing(_ key: TopicCoverKey) { preparing.remove(key) }

    /// Ein neues Bild auf Wunsch, auch wenn das alte noch passt.
    func regenerate(_ recipe: TopicCoverRecipe) async -> Outcome {
        let key = recipe.key
        await loadIfNeeded(key)
        switch availability {
        case .dialogOnly: return .needsDialog
        case .unavailable: return TopicCoverGenerator.isDialogAvailable ? .needsDialog : .unavailable
        case .unknown, .available: break
        }
        outcomes[key] = nil
        removed.remove(key)
        enqueue(recipe)
        while generating.contains(key), let worker { await worker.value }
        return outcomes[key] ?? .failed
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
        covers[recipe.key] = cover
        attempted[recipe.key] = recipe.digest
        onChange?()
        return true
    }

    /// Ein gelöschtes Update nimmt sein Bild und die seiner Ausgaben mit.
    func remove(_ feedID: SmartFeedID) {
        for key in knownKeys where key.feedID == feedID { forget(key) }
        removed.insert(TopicCoverKey(feedID: feedID))
        pending.removeAll { $0.feedID == feedID }
        let store = self.store
        Task.detached(priority: .utility) { store.remove(feedID) }
    }

    /// Eine gelöschte Ausgabe nimmt ihr Bild mit.
    func removeEdition(_ key: TopicCoverKey) {
        guard key.editionID != nil else { return remove(key.feedID) }
        forget(key)
        removed.insert(key)
        pending.removeAll { $0.key == key }
        let store = self.store
        Task.detached(priority: .utility) { store.remove(key) }
    }

    /// Behält nur die Bilder der Updates und Ausgaben, die es noch gibt.
    ///
    /// Ein Update oder eine Ausgabe, die auf einem anderen Gerät gelöscht
    /// wurde, kommt hier nicht über `remove(_:)` an, sondern fehlt nach dem
    /// Abgleich einfach in der Liste. Ein Bild, das gerade entsteht, bleibt:
    /// sein Besitzer kann eben erst angelegt und noch nicht gespeichert sein.
    func retain(feeds: Set<SmartFeedID>, editions: Set<TopicCoverKey>) {
        let keptFeeds = feeds.union(generating.map(\.feedID))
        let keptEditions = editions.union(generating.filter { $0.editionID != nil })
        for key in knownKeys {
            let alive = key.editionID == nil ? keptFeeds.contains(key.feedID) : keptEditions.contains(key)
            if !alive { forget(key) }
        }
        let store = self.store
        Task.detached(priority: .utility) {
            store.removeAll(except: keptFeeds)
            store.removeEditionCovers(except: keptEditions)
        }
    }

    /// Das Bild für den Sperrbildschirm: das der Ausgabe, sonst das des
    /// Updates, sonst das Layout.
    func nowPlayingArtwork(
        for feed: SmartPodcastFeed, edition: PersonalEpisode?, layout: CoverAsset
    ) -> EpisodePlayer.FocusArtwork {
        let keys = [edition.map { TopicCoverKey(feedID: feed.id, editionID: $0.id) },
                    TopicCoverKey(feedID: feed.id)].compactMap { $0 }
        for key in keys {
            if let cover = covers[key] {
                let stamp = Int(cover.stored.createdAt.timeIntervalSince1970)
                return EpisodePlayer.FocusArtwork(
                    key: "cover-\(feed.id.rawValue)-\(key.editionID?.rawValue ?? "")-\(cover.stored.digest)-\(stamp)",
                    image: cover.image)
            }
        }
        // Über Siri gestartet ist das Bild vielleicht noch nicht geladen.
        for key in keys where loads[key] == nil {
            Task {
                await loadIfNeeded(key)
                if covers[key] != nil { onChange?() }
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

    private var knownKeys: Set<TopicCoverKey> {
        Set(covers.keys).union(attempted.keys).union(loads.keys).union(outcomes.keys)
    }

    private func forget(_ key: TopicCoverKey) {
        covers[key] = nil
        attempted[key] = nil
        loads[key] = nil
        outcomes[key] = nil
        followUps[key] = nil
    }

    private func loadIfNeeded(_ key: TopicCoverKey) async {
        if let load = loads[key] {
            await load.value
            return
        }
        let store = self.store
        let load = Task {
            let found = await Task.detached(priority: .utility) { () -> TopicCover? in
                guard let stored = store.stored(for: key),
                      let image = TopicCoverStore.loadImage(at: stored.url) else { return nil }
                return TopicCover(stored: stored, image: image)
            }.value
            if let found, covers[key] == nil, !removed.contains(key) { covers[key] = found }
        }
        loads[key] = load
        await load.value
    }

    private func enqueue(_ recipe: TopicCoverRecipe) {
        let key = recipe.key
        attempted[key] = recipe.digest
        // Entsteht dieses Bild schon, gilt das neueste Rezept. Wartet es
        // noch, ersetzt es das alte. Läuft es gerade, kommt es danach dran.
        // Sonst bliebe das Bild zu den alten Tags stehen.
        if generating.contains(key) {
            if let index = pending.firstIndex(where: { $0.key == key }) {
                pending[index] = recipe
            } else {
                followUps[key] = recipe
            }
            return
        }
        removed.remove(key)
        generating.insert(key)
        pending.append(recipe)
        if worker == nil {
            worker = Task { await drain() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let recipe = pending.removeFirst()
            let outcome = await generate(recipe)
            outcomes[recipe.key] = outcome
            generating.remove(recipe.key)
            // Während das Bild entstand, änderten sich die Tags. Gleich
            // weiter geht es nur, wenn Image Playground bereitsteht. Nach
            // einem Aufschub versucht es das nächste Erscheinen ohnehin.
            if let next = followUps.removeValue(forKey: recipe.key),
               next.digest != recipe.digest, outcome == .created || outcome == .failed {
                enqueue(next)
            }
        }
        worker = nil
    }

    private func generate(_ recipe: TopicCoverRecipe) async -> Outcome {
        let store = self.store
        let key = recipe.key
        do {
            let cover = try await Task.detached(priority: .userInitiated) {
                try await store.generate(for: recipe)
            }.value
            availability = .available
            // Während das Bild entstand, wurde sein Besitzer gelöscht.
            guard !removed.contains(key), !removed.contains(TopicCoverKey(feedID: key.feedID)) else {
                Task.detached(priority: .utility) { store.remove(key) }
                return .failed
            }
            covers[key] = cover
            onChange?()
            return .created
        } catch TopicCoverGenerator.Failure.unavailable {
            let dialog = TopicCoverGenerator.isDialogAvailable
            availability = dialog ? .dialogOnly : .unavailable
            // Was noch wartet, entsteht auf diesem Weg auch nicht.
            let outcome: Outcome = dialog ? .needsDialog : .unavailable
            for waiting in pending {
                generating.remove(waiting.key)
                outcomes[waiting.key] = outcome
            }
            pending.removeAll()
            return outcome
        } catch TopicCoverGenerator.Failure.notInForeground {
            // Beim nächsten Wechsel in den Vordergrund noch einmal.
            attempted[key] = nil
            return .postponed
        } catch TopicCoverGenerator.Failure.cancelled {
            attempted[key] = nil
            return .postponed
        } catch {
            return .failed
        }
    }
}

// MARK: - Modell

extension AppModel {

    /// Die Tags eines Updates als Begriffe, in der Reihenfolge des Updates.
    func coverRecipe(for feed: SmartPodcastFeed) -> TopicCoverRecipe {
        TopicCoverRecipe(feed: feed, topics: labels(forTags: feed.topicIDs))
    }

    /// Das Rezept für das Cover einer Ausgabe: ihre Tags und die zwei
    /// Namen, die in ihren Stellen am häufigsten fallen. Die Namen kommen
    /// aus den Nennungen der Originalfolgen, ohne Modell.
    func coverRecipe(for edition: PersonalEpisode, feed: SmartPodcastFeed) async -> TopicCoverRecipe {
        var tagIDs: [InterestID] = []
        for id in edition.overviewEntries.flatMap(\.tagIDs) + edition.segments.flatMap(\.topicIDs)
        where !tagIDs.contains(id) {
            tagIDs.append(id)
        }
        let topics = labels(forTags: tagIDs.isEmpty ? feed.topicIDs : tagIDs)
        let episodeIDs = Array(Set(edition.segments.map(\.episodeID))).sorted { $0.rawValue < $1.rawValue }
        let episodes = ((try? await store.episodes(ids: episodeIDs.prefix(Self.coverNameEpisodeLimit).map { $0 }))
            ?? [])
        var mentions: [EpisodeID: [Mention]] = [:]
        for episode in episodes {
            mentions[episode.id] = await self.mentions(for: episode).mentions
        }
        let names = EditionCoverNames.mostFrequent(in: edition, mentions: mentions, excluding: topics)
        return TopicCoverRecipe(edition: edition, feed: feed, topics: topics, names: names)
    }

    /// So viele Folgen einer Ausgabe werden nach Namen durchsucht. Mehr
    /// kostet nur Zeit, die zwei häufigsten stehen dann längst fest.
    static let coverNameEpisodeLimit = 8

    /// Legt das Cover einer Ausgabe an, falls es fehlt. Nur im Vordergrund
    /// sinnvoll; im Hintergrund lehnt Image Playground ab, und der nächste
    /// Wechsel in den Vordergrund holt es nach.
    func prepareCover(for edition: PersonalEpisode) async {
        guard let feed = smartFeeds.first(where: { $0.id == edition.feedID }) else { return }
        let key = TopicCoverKey(feedID: feed.id, editionID: edition.id)
        // Liste, Kopf und Player zeigen dieselbe Ausgabe oft gleichzeitig.
        // Das Rezept mit seinen Namen entsteht trotzdem nur einmal.
        guard coverArt.mayGenerate, !coverArt.wasAttempted(key), coverArt.beginPreparing(key) else { return }
        defer { coverArt.endPreparing(key) }
        guard !(await coverArt.hasCover(key)) else { return }
        await coverArt.prepare(await coverRecipe(for: edition, feed: feed))
    }

    /// Holt die Cover der neuesten Ausgaben nach, etwa von Ausgaben, die im
    /// Hintergrund entstanden sind. Beim Wechsel in den Vordergrund und
    /// nach einer neuen Ausgabe. Ältere Ausgaben bekommen ihr Bild, sobald
    /// sie jemand öffnet.
    func prepareMissingEditionCovers() async {
        guard coverArt.mayGenerate else { return }
        for feed in smartFeeds {
            for edition in PersonalEpisode.latestRun(in: editions[feed.id] ?? []) {
                await prepareCover(for: edition)
            }
        }
    }

    /// Bezeichnungen zu Tag-Kennungen, in dieser Reihenfolge.
    func labels(forTags ids: [InterestID]) -> [String] {
        ids.compactMap { id in profile.interests.first { $0.id == id }?.label }
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

    /// Was der Sperrbildschirm zu einem Fokus-Plan zeigt: das Cover der
    /// Ausgabe, sonst das Cover des Podcasts der laufenden Stelle.
    func focusArtwork(for plan: ValidatedPlaybackPlan, segment: PlanSegment) -> EpisodePlayer.FocusArtwork? {
        if let edition = edition(playing: plan),
           let feed = smartFeeds.first(where: { $0.id == edition.feedID }) {
            let layout = cover(for: edition) ?? NativeCoverRenderer().makeCover(for: feed)
            return coverArt.nowPlayingArtwork(for: feed, edition: edition, layout: layout)
        }
        guard let url = podcastArtworkURL(for: segment) else { return nil }
        return EpisodePlayer.FocusArtwork(key: url.absoluteString, url: url)
    }

    /// „Teil 2 von 3“, bei einem Lauf aus einem Teil nichts.
    func partLabel(for edition: PersonalEpisode) -> String? {
        let count = edition.partCount(in: editions[edition.feedID] ?? [])
        guard count > 1 else { return nil }
        return String(localized: "Teil \(edition.part) von \(count)")
    }
}
