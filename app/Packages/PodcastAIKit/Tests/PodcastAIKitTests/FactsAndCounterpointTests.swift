//
//  FactsAndCounterpointTests.swift
//  PodcastAIKitTests
//
//  Fakten zeigen auf ihren Satz und tragen Schlagworte. Gegenpositionen
//  behalten ihre Relevanzfolge und behaupten nichts, was nicht eingeordnet
//  wurde. „Vertiefen“ plant die angekündigten Stellen.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIKnowledge
@testable import PodcastAIExport

private let media = MediaVersionID(stable: "m")

private func ms(_ seconds: Int) -> MediaTime { MediaTime(milliseconds: Int64(seconds) * 1000) }

private func segment(_ start: Int, _ end: Int, _ text: String) -> TranscriptSegment {
    TranscriptSegment(id: SegmentID(stable: "s\(start)"),
                      range: MediaTimeRange(start: ms(start), end: ms(end)), text: text)
}

private func passage(_ key: String, _ text: String, from start: Int = 0, to end: Int = 60) -> Evidence {
    Evidence(id: EvidenceID(stable: key), mediaVersionID: media, episodeID: EpisodeID(stable: "e"),
             sourceID: SourceID(stable: "q"), transcriptID: TranscriptID(stable: "t"),
             transcriptRevision: .initial, range: MediaTimeRange(start: ms(start), end: ms(end)),
             quotedText: text)
}

private func candidate(_ key: String, _ relation: CounterpointRelation, confirmed: Bool = true) -> CounterpointCandidate {
    CounterpointCandidate(evidenceID: EvidenceID(rawValue: key), relation: relation,
                          isModelConfirmed: confirmed, sourceTitle: "Quelle", excerpt: key)
}

@Suite("Fakten: Satz, Wortlaut, Schlagworte")
struct FactAnchorTests {

    private let segments = [
        segment(0, 12, "Viele Unternehmen testen KI-Assistenten zuerst im Kundenservice."),
        segment(12, 25, "Ein Problem ist der Datenschutz, denn Anfragen enthalten persönliche Daten."),
        segment(25, 40, "Modelle auf dem Gerät verarbeiten Text lokal, dadurch verlassen Daten das Telefon nicht."),
        segment(40, 60, "Für größere Aufgaben gibt es Serverlösungen."),
        segment(60, 80, "Modelle auf dem Gerät sind das Thema der nächsten Passage."),
    ]

    @Test("Die Zeitmarke zeigt auf den Satz, nicht auf den Anfang der Passage")
    func anchorsOnSentence() {
        let range = FactAnchor.range(
            for: "Modelle auf dem Gerät verarbeiten Text lokal, Daten verlassen das Telefon nicht.",
            within: MediaTimeRange(start: ms(0), end: ms(60)), in: segments)
        #expect(range == MediaTimeRange(start: ms(25), end: ms(40)))
    }

    @Test("Gesucht wird nur im Beleg")
    func staysInsidePassage() {
        let range = FactAnchor.range(
            for: "Modelle auf dem Gerät", within: MediaTimeRange(start: ms(60), end: ms(80)), in: segments)
        #expect(range == MediaTimeRange(start: ms(60), end: ms(80)))
    }

    @Test("Ohne gemeinsames Wort bleibt es beim Beleg")
    func noOverlapNoAnchor() {
        let range = FactAnchor.range(
            for: "Wasserstoff ist teuer.", within: MediaTimeRange(start: ms(0), end: ms(60)), in: segments)
        #expect(range == nil)
    }

    @Test("Ältere Fakten bekommen ihren Satz, verankerte bleiben, wie sie sind")
    func anchorsOnlyPassageFacts() {
        let transcript = Transcript(
            id: TranscriptID(stable: "t"), mediaVersionID: media, revision: .initial,
            origin: .speechAnalysis, locale: "de_DE", segments: segments,
            analyzedRanges: IntervalSet(MediaTimeRange(start: ms(0), end: ms(80))))
        func fact(_ id: String, _ statement: String, _ range: MediaTimeRange) -> EpisodeFact {
            EpisodeFact(id: id, episodeID: EpisodeID(stable: "e"), sourceID: SourceID(stable: "q"),
                        evidenceID: EvidenceID(stable: "p"), mediaVersionID: media,
                        statement: statement, range: range, modelTier: "Test")
        }
        let old = fact("a", "Anfragen enthalten persönliche Daten, das ist ein Problem für den Datenschutz.",
                       MediaTimeRange(start: ms(0), end: ms(60)))
        let fresh = fact("b", "Unternehmen testen KI-Assistenten im Kundenservice.",
                         MediaTimeRange(start: ms(0), end: ms(12)))
        let result = FactAnchor.anchored([old, fresh], in: transcript)
        #expect(result[0].range == MediaTimeRange(start: ms(12), end: ms(25)))
        #expect(result[1] == fresh)
    }

    @Test("Der Wortlaut ist der passende Satz aus dem Beleg")
    func wordingIsMatchingSentence() {
        let text = segments.prefix(4).map(\.text).joined(separator: " ")
        let wording = FactAnchor.wording(
            for: "Daten verlassen das Telefon nicht, weil Modelle lokal rechnen.", in: text)
        #expect(wording.hasPrefix("Modelle auf dem Gerät verarbeiten Text lokal"))
        #expect(!wording.contains("Kundenservice"))
    }

    @Test("Schlagworte: eigene Interessen zuerst, dann wiederkehrende Hauptwörter")
    func topicTags() {
        let statements = [
            "Teams brauchen klare Regeln für den Einsatz von Sprachmodellen.",
            "Ohne klare Regeln entstehen Schattenlösungen.",
            "Die neue Verordnung verlangt Transparenz bei Sprachmodellen.",
        ]
        let passages = [
            passage("p1", "Teams setzen Sprachmodelle ein und brauchen Regeln."),
            passage("p2", "Der Datenschutz ist bei Anfragen entscheidend."),
            passage("p3", "Die Verordnung verlangt Transparenz."),
        ]
        let profile = InterestProfile(interests: [
            Interest(label: "Datenschutz", kind: .topic, origin: .confirmedByUser),
            Interest(label: "Gartenbau", kind: .topic, origin: .confirmedByUser),
        ])
        let tags = TopicTagger().tags(statements: statements, passages: passages, profile: profile)
        #expect(tags.first?.label == "Datenschutz")
        #expect(tags.first?.isInterest == true)
        #expect(!tags.contains { $0.label == "Gartenbau" })
        #expect(tags.contains { $0.label == "Regeln" && !$0.isInterest })
        // Die Aussagen sagen „bei Sprachmodellen“, ein Beleg „Sprachmodelle“.
        // Das Schlagwort steht in der kürzeren Form.
        #expect(tags.contains { $0.label == "Sprachmodelle" })
        #expect(!tags.contains { $0.label == "Sprachmodellen" })
        // Satzanfänge sind keine Hauptwörter, „Teams“ steht nur dort.
        #expect(!tags.contains { $0.label == "Teams" })
        // Nur einmal gesagt und kaum im Transkript: kein Schlagwort.
        #expect(!tags.contains { $0.label == "Schattenlösungen" })
    }

    @Test("Ein Schlagwort steht in der Grundform, die die Folge belegt, und trifft als Interesse alle Formen")
    func topicTagUsesBaseForm() throws {
        let statements = [
            "Firmen setzen bei Sprachmodellen auf eigene Daten.",
            "Der Bericht warnt vor Fehlern bei Sprachmodellen.",
        ]
        let passages = [
            passage("p1", "Ein Sprachmodell rechnet auf dem Gerät."),
            passage("p2", "Die Sprachmodelle werden kleiner."),
            passage("p3", "Bei Sprachmodellen hilft das."),
        ]
        let tags = TopicTagger().tags(statements: statements, passages: passages, profile: InterestProfile())
        let tag = try #require(tags.first { $0.label.hasPrefix("Sprachmodell") })
        #expect(tag.label == "Sprachmodell")

        // Getippt wird daraus ein Interesse mit genau dieser Bezeichnung.
        let interest = Interest(label: tag.label, kind: .topic, origin: .confirmedByUser)
        let matched = Set(RelevanceScorer().score(evidence: passages, profile: InterestProfile(interests: [interest]))
            .map(\.evidenceID))
        #expect(matched == Set(passages.map(\.id)))
    }

    @Test("Gekürzt wird nur auf eine Form, die vorkommt")
    func topicTagKeepsUnattestedForms() {
        let statements = [
            "Viele Unternehmen testen neue Werkzeuge.",
            "Kleine Unternehmen zögern noch, sagt ein Unternehmer.",
        ]
        let passages = [passage("p1", "Der Unternehmer spricht über Unternehmen und Regeln.")]
        let tags = TopicTagger().tags(statements: statements, passages: passages, profile: InterestProfile())
        #expect(tags.contains { $0.label == "Unternehmen" })
        #expect(!tags.contains { $0.label == "Unternehm" })
        #expect(TopicTagger.baseForm(of: "batterien") { $0 == "batterie" } == "batterie")
        #expect(TopicTagger.baseForm(of: "regeln") { _ in false } == "regeln")
        // Unter fünf Buchstaben wird nicht gekürzt.
        #expect(TopicTagger.baseForm(of: "daten") { $0 == "date" } == "daten")
    }

    @Test("Offene Fragen und Vorhaben werden keine Schlagworte")
    func questionsAndProjectsAreNoTags() {
        let passages = [
            passage("p1", "Agentische Apps nutzen in iOS 27 neue Schnittstellen."),
            passage("p2", "Für agentische Apps öffnet Apple weitere Möglichkeiten."),
        ]
        let profile = InterestProfile(interests: [
            Interest(label: "Welche Möglichkeiten bietet iOS 27 für agentische Apps?",
                     kind: .openQuestion, origin: .confirmedByUser),
            Interest(label: "Agentische Apps bauen", kind: .activeProject, origin: .confirmedByUser),
            Interest(label: "Schnittstellen", kind: .topic, origin: .confirmedByUser),
        ])
        // Die Frage und das Vorhaben treffen beide Stellen.
        let kinds = Set(RelevanceScorer().score(evidence: passages, profile: profile).map(\.kind))
        #expect(kinds.contains(.openQuestion) && kinds.contains(.activeProject))

        let tags = TopicTagger().tags(statements: [], passages: passages, profile: profile)
        #expect(tags.map(\.label) == ["Schnittstellen"])
    }

    @Test("Zu Themen gewordene Fragen und Vorhaben werden keine Schlagworte")
    func convertedQuestionsAreNoTags() {
        let passages = [
            passage("p1", "Agentische Apps nutzen in iOS 27 neue Schnittstellen."),
            passage("p2", "Für agentische Apps öffnet Apple weitere Möglichkeiten."),
        ]
        let legacy = [
            Interest(label: "Welche Möglichkeiten bietet iOS 27 für agentische Apps?",
                     kind: .openQuestion, origin: .confirmedByUser),
            Interest(label: "Eine eigene App für agentische Abläufe bauen",
                     kind: .activeProject, origin: .confirmedByUser),
            Interest(label: "Schnittstellen", kind: .topic, origin: .confirmedByUser),
        ]
        // Wie beim Laden des Profils: aus Fragen und Vorhaben werden Themen.
        let converted = legacy.map { interest -> Interest in
            var topic = interest
            topic.kind = .topic
            topic.expiresAt = nil
            return topic
        }
        let profile = InterestProfile(interests: converted)
        #expect(profile.topics.count == 3)

        let tags = TopicTagger().tags(statements: [], passages: passages, profile: profile)
        #expect(tags.map(\.label) == ["Schnittstellen"])
        #expect(TopicTagger.isTagShaped("Künstliche Intelligenz"))
        #expect(!TopicTagger.isTagShaped("Was kann KI?"))
    }

    @Test("Zu Wahlen und Parteien schlägt die App kein Schlagwort vor")
    func sensitiveTopicsStayOut() {
        let statements = ["Vor der Wahl streiten die Parteien.", "Nach der Wahl regieren die Parteien."]
        let tags = TopicTagger().tags(statements: statements, passages: [], profile: InterestProfile())
        #expect(tags.isEmpty)
    }

    @Test("Der Export nennt Zeitspanne und Wortlaut je Fakt")
    func exportShowsWordingAndSpan() {
        let fact = EpisodeFact(
            id: "f1", episodeID: EpisodeID(stable: "e"), sourceID: SourceID(stable: "q"),
            evidenceID: EvidenceID(stable: "p"), mediaVersionID: media,
            statement: "Daten bleiben auf dem Gerät.", range: MediaTimeRange(start: ms(25), end: ms(40)),
            modelTier: "Test")
        let dossier = EpisodeDossier(title: "Folge", sourceTitle: "Podcast", facts: [fact],
                                     factQuotes: ["f1": "Dadurch verlassen Daten das Telefon nicht."])
        let text = EpisodeDossierExporter().markdown(dossier, includeTranscript: false)
        #expect(text.contains("Daten bleiben auf dem Gerät. (`0:25–0:40`)"))
        #expect(text.contains("  > Dadurch verlassen Daten das Telefon nicht."))
    }
}

@Suite("Gegenpositionen und Vertiefen")
struct CounterpointAndClosureTests {

    @Test("Innerhalb einer Gruppe bleibt die Relevanzfolge, nicht die Kennung")
    func mixerKeepsRelevanceOrder() {
        let input = [
            candidate("z-best", .contradicts), candidate("a-second", .contradicts),
            candidate("m-third", .contradicts), candidate("b-fourth", .contradicts),
        ]
        let picked = CounterpointMixer().balance(input).map(\.evidenceID.rawValue)
        #expect(picked == ["z-best", "a-second", "m-third"])
    }

    @Test("Nicht Eingeordnetes steht am Ende und behauptet keine fehlende Gegenposition")
    func unclassifiedMakesNoClaim() {
        let mixer = CounterpointMixer()
        let unclassified = (1...8).map { candidate("u\($0)", .unclassified, confirmed: false) }
        let picked = mixer.balance(unclassified)
        #expect(picked.count == 6)
        #expect(picked.first?.evidenceID.rawValue == "u1")
        #expect(mixer.imbalanceNotice(picked) == nil)

        // Nur ein Teil eingeordnet: keine Behauptung über die fehlende Seite,
        // denn unter den übrigen kann sie sein.
        let mixed = mixer.balance([candidate("u", .unclassified, confirmed: false), candidate("s", .supports)])
        #expect(mixed.map(\.relation) == [.supports, .unclassified])
        let notice = mixer.imbalanceNotice(mixed)
        #expect(notice?.contains(TestLanguage.pick(de: "nicht eingeordnet", en: "aren't classified")) == true)
        #expect(notice?.contains("findet sich keine Gegenposition") == false)

        let against = mixer.balance([candidate("u", .unclassified, confirmed: false), candidate("c", .contradicts)])
        #expect(mixer.imbalanceNotice(against)?.contains(TestLanguage.pick(de: "nicht eingeordnet", en: "aren't classified")) == true)
        #expect(mixer.imbalanceNotice(against)?.contains("findet sich nur die Gegenseite") == false)

        // Alles eingeordnet und keine Gegenposition: das darf die App sagen.
        let classified = mixer.balance([candidate("s", .supports), candidate("d", .differentPremise)])
        #expect(mixer.imbalanceNotice(classified)?.contains(TestLanguage.pick(de: "findet sich keine Gegenposition", en: "no counterpoint")) == true)
        #expect(mixer.imbalanceNotice([])?.contains(TestLanguage.pick(de: "Folgen mit Transkript", en: "transcribed episodes")) == true)
    }

    @Test("Ob eine These gesichert ist, ergibt sich aus den Karten")
    func savedThesisFollowsTrails() {
        let check = CounterpointCheck(
            thesis: "Kernkraft ist klimafreundlich", isRunning: false,
            candidates: [candidate("s", .supports), candidate("c", .contradicts),
                         candidate("u", .unclassified, confirmed: false)])
        #expect(!check.isSaved(in: []))

        let trail = check.trail(question: "These: Kernkraft ist klimafreundlich")
        #expect(trail.id == check.trailID)
        #expect(trail.evidenceIDs.map(\.rawValue) == ["s", "c", "u"])
        #expect(trail.counterpointEvidenceIDs.map(\.rawValue) == ["c"])
        #expect(trail.isThesisCheck)
        #expect(check.isSaved(in: [trail]))

        // Karte gelöscht: die Prüfung lässt sich wieder sichern.
        #expect(!check.isSaved(in: []))
        // Eine neue Prüfung derselben These ist eine eigene Karte.
        let again = CounterpointCheck(thesis: check.thesis, isRunning: false, candidates: check.candidates)
        #expect(again.trailID != check.trailID)
        #expect(!again.isSaved(in: [trail]))

        // Eine Karte aus dem Chat ist keine geprüfte These.
        #expect(!KnowledgeTrail(question: "Was sagt A?", evidenceIDs: [EvidenceID(rawValue: "s")]).isThesisCheck)
    }

    @Test("Das Modell wählt nie „nicht eingeordnet“")
    func unclassifiedIsNotAModelLabel() {
        #expect(!CounterpointRelation.classifiable.contains(.unclassified))
        #expect(CounterpointRelation.classifiable.count == CounterpointRelation.allCases.count - 1)
    }

    @Test("Vertiefen kennt die angekündigten Stellen, nicht das eben Gehörte")
    func closureCarriesFollowUps() {
        let heard = [EvidenceID(stable: "gehört")]
        let next = [EvidenceID(stable: "neu1"), EvidenceID(stable: "neu2")]
        let closure = SessionClosure(question: "Frage", supportingEvidenceIDs: heard, followUpEvidenceIDs: next)
        #expect(closure.canDeepen)
        #expect(closure.availableFollowUpCount == 2)
        #expect(closure.followUpLabel == TestLanguage.pick(de: "2 weitere Stellen dazu, höchstens 10 Minuten.", en: "2 more passages on this, up to 10 minutes."))

        let empty = SessionClosure(question: "Frage", supportingEvidenceIDs: heard)
        #expect(!empty.canDeepen)
        #expect(empty.followUpLabel == TestLanguage.pick(de: "Dazu gibt es keine weitere Stelle mit Transkript.", en: "There are no more transcribed passages on this."))
    }
}
