//
//  AudioPolicyTests.swift
//  PodcastAIKitTests
//
//  Aus dem TestFlight-Feedback zu 0.7.1: die neueste Folge je Podcast
//  bleibt für unterwegs, alle anderen spielen nach dem Transkript aus dem
//  Netz, und was jemand selbst lädt, bleibt bis „Audio entfernen“. Dazu die
//  Rückfrage vor „Ältere Folgen auch vorbereiten“ mit Anzahl und Größe.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAICore
@testable import PodcastAIKnowledge

@Suite("Audio auf dem Gerät und ältere Folgen")
struct AudioPolicyTests {

    private let defaults = AudioRetention.Rules(removeAfterTranscript: true, removeHeard: true, keepNewest: true)

    private func verdict(_ facts: AudioRetention.Facts,
                         rules: AudioRetention.Rules? = nil) -> AudioRetention.Verdict {
        AudioRetention.verdict(for: facts, rules: rules ?? defaults)
    }

    // MARK: Behalten und Entfernen

    @Test("Von Hand geladen bleibt, auch mit Transkript, gehört und nicht mehr neueste")
    func keptByUserAlwaysStays() {
        let facts = AudioRetention.Facts(keptByUser: true, isNewest: false, hasTranscript: true,
                                         heardLongAgo: true, prefetched: true)
        #expect(verdict(facts) == .keptByUser)
        #expect(!verdict(facts).isTemporary)
    }

    @Test("Die neueste Folge bleibt nach dem Transkript liegen")
    func newestStaysAfterTranscript() {
        #expect(verdict(.init(isNewest: true, hasTranscript: true)) == .newest)
        #expect(verdict(.init(isNewest: true, prefetched: true)) == .newest)
    }

    @Test("Jede andere Folge verliert den Ton nach dem Transkript")
    func olderEpisodeLosesAudioAfterTranscript() {
        #expect(verdict(.init(hasTranscript: true)) == .remove)
        #expect(verdict(.init()) == .removeAfterTranscript)
    }

    @Test("Kommt eine neuere Folge, geht die vorher nur vorgehaltene")
    func supersededPrefetchIsRemoved() {
        // Ohne Transkript und mit allen Aufräumregeln aus: nur geladen, weil
        // sie die neueste war. Das ist sie nicht mehr.
        let off = AudioRetention.Rules(removeAfterTranscript: false, removeHeard: false, keepNewest: true)
        #expect(verdict(.init(prefetched: true), rules: off) == .remove)
        // Eine selbst geladene Datei bleibt dagegen auch dann.
        #expect(verdict(.init(keptByUser: true, prefetched: true), rules: off) == .keptByUser)
    }

    @Test("Eine gehörte neueste Folge geht nach einem Tag wie jede andere")
    func heardNewestIsRemovedAfterADay() {
        #expect(verdict(.init(isNewest: true, heardLongAgo: true)) == .remove)
        // Mit „Gehörte Folgen entfernen“ aus bleibt sie die neueste.
        let keepHeard = AudioRetention.Rules(removeAfterTranscript: true, removeHeard: false, keepNewest: true)
        #expect(verdict(.init(isNewest: true, heardLongAgo: true), rules: keepHeard) == .newest)
    }

    @Test("Ohne „Neueste Folge behalten“ gilt für die neueste dasselbe wie für alle")
    func keepNewestOff() {
        let rules = AudioRetention.Rules(removeAfterTranscript: true, removeHeard: true, keepNewest: false)
        #expect(verdict(.init(isNewest: true, hasTranscript: true), rules: rules) == .remove)
        #expect(verdict(.init(isNewest: true, prefetched: true), rules: rules) == .remove)
        #expect(verdict(.init(isNewest: true), rules: rules) == .removeAfterTranscript)
    }

    @Test("Mit allen Regeln aus bleibt eine Datei, die niemand nur vorgehalten hat")
    func everythingOffKeepsFiles() {
        let off = AudioRetention.Rules(removeAfterTranscript: false, removeHeard: false, keepNewest: false)
        #expect(verdict(.init(hasTranscript: true, heardLongAgo: true), rules: off) == .stays)
        let heardOnly = AudioRetention.Rules(removeAfterTranscript: false, removeHeard: true, keepNewest: false)
        #expect(verdict(.init(hasTranscript: true), rules: heardOnly) == .removeAfterHeard)
    }

    @Test("Die neueste Folge ist die erste mit Audiodatei")
    func newestIsFirstWithAudio() {
        let source = SourceID(stable: "quelle-neueste")
        let video = Episode(id: EpisodeID(stable: "video"), sourceID: source, title: "Nur Video")
        let audio = Episode(id: EpisodeID(stable: "audio"), sourceID: source, title: "Mit Ton",
                            audioURL: URL(string: "https://example.com/a.mp3"))
        let older = Episode(id: EpisodeID(stable: "alt"), sourceID: source, title: "Älter",
                            audioURL: URL(string: "https://example.com/b.mp3"))
        #expect(AudioRetention.newest(in: [video, audio, older])?.id == audio.id)
        #expect(AudioRetention.newest(in: [video]) == nil)
    }

    @Test("Die bisherige neueste Folge bleibt, bis der Ton der neuen da ist")
    func previousNewestStaysUntilNewArrives() {
        let source = SourceID(stable: "quelle-wechsel")
        func episode(_ name: String) -> Episode {
            Episode(id: EpisodeID(stable: name), sourceID: source, title: name,
                    audioURL: URL(string: "https://example.com/\(name).mp3"))
        }
        let new = episode("neu"), previous = episode("bisher"), old = episode("alt")
        let list = [new, previous, old]
        // Die neue wartet noch aufs WLAN: die bisherige bleibt.
        #expect(AudioRetention.keptAsNewest(in: list, hasFile: { $0.id != new.id }, isComing: { _ in true })
                == [new.id, previous.id])
        // Die neue ist da: nur sie bleibt.
        #expect(AudioRetention.keptAsNewest(in: list, hasFile: { _ in true }, isComing: { _ in true }) == [new.id])
        // Die neue kommt nicht mehr, etwa abgebrochen: nichts hält die bisherige.
        #expect(AudioRetention.keptAsNewest(in: list, hasFile: { $0.id != new.id }, isComing: { _ in false })
                == [new.id])
        // Liegt gar nichts auf dem Gerät, bleibt es bei der neuesten.
        #expect(AudioRetention.keptAsNewest(in: list, hasFile: { _ in false }, isComing: { _ in true }) == [new.id])
        #expect(AudioRetention.keptAsNewest(in: [], hasFile: { _ in true }, isComing: { _ in true }).isEmpty)
    }

    // MARK: Ältere Folgen vorbereiten

    private func episode(_ index: Int, minutes: Int?) -> Episode {
        Episode(id: EpisodeID(stable: "alt-\(index)"), sourceID: SourceID(stable: "quelle-alt"),
                title: "Folge \(index)", declaredDuration: minutes.map { MediaDuration(minutes: $0) },
                audioURL: URL(string: "https://example.com/\(index).mp3"))
    }

    @Test("Die Schätzung rechnet mit 128 kbit/s und füllt fehlende Längen mit dem Mittel")
    func downloadEstimate() {
        // 60 Minuten zu 16 000 Byte je Sekunde.
        #expect(EpisodeArchive.estimatedDownloadBytes(for: [episode(1, minutes: 60)]) == 57_600_000)
        // Eine Folge ohne Länge zählt wie das Mittel der übrigen (45 Minuten).
        let mixed = [episode(1, minutes: 30), episode(2, minutes: 60), episode(3, minutes: nil)]
        #expect(EpisodeArchive.estimatedDownloadBytes(for: mixed) == Int64(3 * 45 * 60 * 16_000))
        // Ohne jede Länge gibt es keine Schätzung, nur die Anzahl.
        #expect(EpisodeArchive.estimatedDownloadBytes(for: [episode(1, minutes: nil)]) == nil)
        #expect(EpisodeArchive.estimatedDownloadBytes(for: []) == nil)
    }

    @Test("Die Rückfrage nennt die Anzahl und nur mit Längen eine Größe")
    func backCatalogSummary() {
        let withLengths = EpisodeArchive.backCatalogSummary([episode(1, minutes: 60), episode(2, minutes: 40)])
        #expect(withLengths.hasPrefix(TestLanguage.pick(de: "2 Folgen noch ohne Transkript, zusammen etwa ",
                                                         en: "2 episodes still without a transcript, about ")))
        #expect(EpisodeArchive.backCatalogSummary([episode(1, minutes: nil)])
                == TestLanguage.pick(de: "1 Folge noch ohne Transkript.", en: "1 episode still without a transcript."))
        // Liegt der Ton schon auf dem Gerät, zählt die Folge mit, geladen wird sie nicht.
        let loaded = EpisodeArchive.backCatalogSummary([episode(1, minutes: 60), episode(2, minutes: 40)],
                                                       toLoad: [episode(2, minutes: 40)])
        #expect(loaded.hasPrefix(TestLanguage.pick(de: "2 Folgen", en: "2 episodes")))
        #expect(loaded != withLengths)
        #expect(EpisodeArchive.backCatalogSummary([episode(1, minutes: 60)], toLoad: [])
                == TestLanguage.pick(de: "1 Folge noch ohne Transkript.", en: "1 episode still without a transcript."))
    }

    @Test("Die Kopfzeile sagt, wenn der Podcast ganz vorbereitet wird")
    func coverageForWholeCatalog() {
        #expect(EpisodeArchive.coverage(total: 412, analyzed: 3, analyzable: true, automatic: .all)
                == TestLanguage.pick(de: "3 von 412 Folgen mit Transkript, automatisch alle",
                                     en: "3 of 412 episodes transcribed, all automatically"))
    }
}
