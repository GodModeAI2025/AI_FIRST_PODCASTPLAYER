//
//  InterestMatchingTests.swift
//  PodcastAIKitTests
//
//  Themen treffen Wörter, keine beliebigen Wortteile. Testpersonen fanden
//  mit „KI“ Kinder und Skigebiete und mit „Führung“ jede Einführung.
//

import Testing
import PodcastAIKit
@testable import PodcastAIKnowledge

@Suite("Themen an Wortgrenzen")
struct InterestMatchingTests {

    private func hits(_ term: String, _ text: String) -> Bool {
        RelevanceScorer.match(terms: [term], in: RelevanceScorer.normalize(text)).0 > 0
    }

    @Test("Kurze Begriffe nur als ganzes Wort")
    func shortTermsNeedWholeWords() {
        #expect(hits("ki", "Wie Teams KI im Alltag nutzen"))
        #expect(hits("ki", "KI-Modelle auf dem Gerät"))
        #expect(!hits("ki", "Die Kinder fahren ins Skigebiet"))
        #expect(!hits("ai", "Im Mai war es warm"))
    }

    @Test("Längere Begriffe am Wortanfang, auch in Zusammensetzungen")
    func longerTermsMatchWordStart() {
        #expect(hits("datenschutz", "Die Datenschutzbeauftragte prüft das"))
        #expect(hits("führung", "Führung im Team ist schwer"))
        #expect(!hits("führung", "Eine kurze Einführung in das Thema"))
    }

    @Test("AI trifft keinen englischen Satz ohne AI")
    func englishSentenceWithoutAI() {
        #expect(!hits("ai", "The main point was the chain of events in the trial"))
        #expect(hits("ai", "AI tools are everywhere now"))
    }

    private func evidence(_ text: String, _ id: String = "e1") -> Evidence {
        Evidence(id: EvidenceID(stable: id), mediaVersionID: MediaVersionID(stable: "m"),
                 episodeID: EpisodeID(stable: "ep"), sourceID: SourceID(stable: "s"),
                 transcriptID: TranscriptID(stable: "t"), transcriptRevision: .initial,
                 range: MediaTimeRange(start: MediaTime(milliseconds: 0), end: MediaTime(milliseconds: 9_000)),
                 quotedText: text)
    }

    private func matches(_ interest: Interest, _ text: String) -> [RelevanceMatch] {
        RelevanceScorer().score(evidence: [evidence(text)], profile: InterestProfile(interests: [interest]))
    }

    @Test("Mehrere Wörter: der ganze Ausdruck oder zwei davon, eines allein reicht nicht")
    func multiWordNeedsPhraseOrTwoWords() {
        let topic = Interest(label: "Lokale KI-Modelle")
        #expect(matches(topic, "Neue Modelle der Autoindustrie kommen im Herbst").isEmpty)
        #expect(matches(topic, "Die lokale Presse berichtet").isEmpty)
        #expect(!matches(topic, "KI-Modelle laufen jetzt auf dem Telefon").isEmpty)
        #expect(!matches(topic, "Modelle, die lokal laufen, und KI im Alltag").isEmpty)
    }

    @Test("Hat ein Ausdruck nur ein tragendes Wort, zählt es allein")
    func singleCarryingWordCounts() {
        #expect(!matches(Interest(label: "Die Bahn"), "Bahnstreik am Montag").isEmpty)
    }

    @Test("Ein einzelnes Stichwort trifft weiter für sich")
    func singleKeywordStillMatches() {
        let topic = Interest(label: "Geldpolitik", keywords: ["EZB", "Leitzins"])
        let found = matches(topic, "Die EZB hebt den Leitzins an")
        #expect(found.count == 1)
        #expect(found.first?.matchedTerms == ["Leitzins", "EZB"])
    }

    @Test("Die Begründung nennt, was erwähnt wird, in der Schreibweise des Nutzers")
    func explanationListsMentionedTerms() {
        let topic = Interest(label: "Geldpolitik", keywords: ["EZB", "Leitzins"])
        let explanation = matches(topic, "Die EZB hebt den Leitzins an").first?.explanation()
        #expect(explanation == TestLanguage.pick(de: "Passt zu deinem Thema „Geldpolitik“ · erwähnt: Leitzins, EZB · Wort kommt vor", en: "Matches your topic \"Geldpolitik\" · mentions: Leitzins, EZB · word appears"))
    }

    @Test("Ein aktuelles Vorhaben steht vor einem gleich guten Thema")
    func activeProjectRanksHigher() {
        let topic = Interest(label: "Datenschutz", kind: .topic)
        let project = Interest(label: "Datenschutz-Audit", kind: .activeProject,
                               keywords: ["Datenschutz"])
        let found = RelevanceScorer().score(
            evidence: [evidence("Datenschutz ist Pflicht")],
            profile: InterestProfile(interests: [topic, project]))
        #expect(found.first?.interestID == project.id)
    }

    @Test("Fragewörter einer offenen Frage sind keine Suchbegriffe")
    func questionWordsAreIgnored() {
        let question = Interest(label: "Welche Möglichkeiten bietet iOS 27 für agentische Apps?", kind: .openQuestion)
        let terms = RelevanceScorer.terms(for: question)
        #expect(!terms.contains("welche"))
        #expect(!terms.contains("bietet"))
        #expect(!terms.contains("möglichkeiten"))
        #expect(terms.contains("agentische"))
    }
}
