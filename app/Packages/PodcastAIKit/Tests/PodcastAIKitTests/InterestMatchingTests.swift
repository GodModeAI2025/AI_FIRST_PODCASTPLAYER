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
