//
//  MentionTests.swift
//
//  Links, Termine, Adressen, Telefonnummern, E-Mail-Adressen und Namen aus
//  Shownotes und Transkript: was erkannt wird, was als Rauschen wegfällt,
//  wie Termine gegen das Erscheinungsdatum aufgelöst werden und welche
//  Fragen der Chat ohne Sprachmodell aus den Nennungen beantwortet.
//
//  Geprüft wird, was von `NSDataDetector` und `NLTagger` verlässlich kommt.
//  Einzelne Wörter aus der Namenserkennung schwanken zwischen
//  Systemversionen und werden deshalb nicht festgenagelt.
//

import Testing
import Foundation
@testable import PodcastAIKit
@testable import PodcastAIKnowledge
@testable import PodcastAIExport

@Suite("Erwähnt: Nennungen in Folgen")
struct MentionTests {

    let calendar = Calendar.current
    let media = MediaVersionID(stable: "mentions-test")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func segments(_ lines: [String], every seconds: Int = 30) -> [TranscriptSegment] {
        lines.enumerated().map { index, line in
            let start = Int64(index * seconds * 1000)
            let range = MediaTimeRange(start: MediaTime(milliseconds: start),
                                       end: MediaTime(milliseconds: start + Int64(seconds * 1000 - 500)))
            return TranscriptSegment(id: TranscriptSegment.stableID(mediaVersionID: media, range: range),
                                     range: range, text: line)
        }
    }

    private func extract(shownotes: String? = nil, lines: [String] = [], language: String = "de_DE",
                         published: Date? = nil, ownHosts: [String] = []) -> [Mention] {
        MentionExtractor().mentions(in: MentionExtractor.Input(
            shownotes: shownotes, segments: segments(lines), languageCode: language,
            publishedAt: published, ownHosts: ownHosts))
    }

    // MARK: - Shownotes

    @Test("Shownotes: Link hinter einer Beschriftung, Termin, Adresse, E-Mail und Telefon")
    func shownotesGerman() throws {
        let html = """
            <p>Alle Infos auf <a href="https://www.example.org/ki-arbeit?utm_source=feed">unserer Seite</a>.
            Workshop am 12. November 2026 um 18 Uhr in der Musterstraße 12, 10115 Berlin.</p>
            <p>Fragen an <a href="mailto:hallo@example.org">hallo@example.org</a> oder Telefon 030 1234567.</p>
            """
        let found = extract(shownotes: html, published: date(2026, 10, 1))

        let link = try #require(found.first { $0.kind == .link })
        #expect(link.normalized == "example.org/ki-arbeit")
        #expect(link.url?.host() == "www.example.org")
        #expect(link.occurrences.first?.origin == .shownotes)
        #expect(link.occurrences.first?.time == nil)

        let email = try #require(found.first { $0.kind == .email })
        #expect(email.normalized == "hallo@example.org")
        #expect(email.url?.absoluteString == "mailto:hallo@example.org")

        let when = try #require(found.first { $0.kind == .date })
        #expect(when.date == date(2026, 11, 12, 18))
        #expect(when.hasTime)
        #expect(!when.isVague)

        let address = try #require(found.first { $0.kind == .address })
        #expect(address.display.contains("Musterstraße 12"))
        #expect(address.url?.host() == "maps.apple.com")

        let phone = try #require(found.first { $0.kind == .phone })
        #expect(phone.normalized == "0301234567")
        #expect(phone.url?.absoluteString == "tel:0301234567")
    }

    @Test("Englische Shownotes: Termin mit Uhrzeit, US-Adresse und Telefon")
    func shownotesEnglish() throws {
        let notes = "Join us on October 12, 2026 at 6 pm at 1 Infinite Loop, Cupertino, CA 95014. Call (408) 996-1010."
        let found = extract(shownotes: notes, language: "en_US", published: date(2026, 9, 1))
        let when = try #require(found.first { $0.kind == .date })
        #expect(when.date == date(2026, 10, 12, 18))
        #expect(found.contains { $0.kind == .address && $0.display.contains("Infinite Loop") })
        #expect(found.contains { $0.kind == .phone && $0.normalized == "4089961010" })
    }

    // MARK: - Gesprochene Webadressen

    @Test("Gesprochene Webadressen mit Endung, Pfad und www werden Links")
    func spokenAddresses() {
        let text = """
            Alle Links findet ihr unter beispiel punkt de slash kontakt. \
            Schaut mal auf www example dot com vorbei. \
            Und mehr unter mein-podcast punkt co punkt uk.
            """
        let found = MentionExtractor.spokenWebAddresses(in: text).map { $0.host + $0.path }
        #expect(found == ["beispiel.de/kontakt", "example.com", "mein-podcast.co.uk"])
    }

    @Test("„Punkt“ im gewöhnlichen Satz ist keine Adresse")
    func spokenAddressNoise() {
        let sentences = [
            "Das ist ein wichtiger Punkt de facto für uns alle.",
            "The dot com bubble burst in the year after.",
            "Er kam auf den Punkt at the end.",
            "Zwei Punkt null ist die neue Version.",
            "Das war der Punkt. De facto ging es weiter.",
        ]
        for sentence in sentences {
            #expect(MentionExtractor.spokenWebAddresses(in: sentence).isEmpty, "\(sentence)")
        }
    }

    @Test("Gesprochener Link im Transkript trägt die Zeitmarke seines Satzes")
    func spokenLinkTime() throws {
        let found = extract(lines: [
            "Willkommen zur Folge.",
            "Die Anmeldung läuft über example punkt org slash workshop.",
        ])
        let link = try #require(found.first { $0.kind == .link })
        #expect(link.normalized == "example.org/workshop")
        #expect(link.url?.absoluteString == "https://example.org/workshop")
        #expect(link.firstTime == MediaTime(milliseconds: 30_000))
        #expect(link.occurrences.first?.context.contains("Anmeldung") == true)
    }

    // MARK: - Termine

    @Test("Termin ohne Jahr gilt ab dem Erscheinen, nicht ab heute, und heißt ungefähr")
    func dateWithoutYear() throws {
        let lines = ["Wir treffen uns am 3. März im Studio."]
        let february = try #require(extract(lines: lines, published: date(2026, 2, 10)).first { $0.kind == .date })
        #expect(february.date == date(2026, 3, 3))
        #expect(february.isVague)
        #expect(!february.hasTime)

        let november = try #require(extract(lines: lines, published: date(2026, 11, 20)).first { $0.kind == .date })
        #expect(november.date == date(2027, 3, 3))

        let christmas = try #require(extract(lines: ["Am 24.12. feiern wir mit euch."],
                                             published: date(2026, 11, 20)).first { $0.kind == .date })
        #expect(christmas.date == date(2026, 12, 24))
        #expect(christmas.isVague)
    }

    @Test("Termin mit Jahr bleibt, wie er ist, auch in der Vergangenheit")
    func dateWithYear() throws {
        let found = extract(lines: ["Am Montag, den 5. Mai 2025 war das Treffen."], published: date(2026, 1, 1))
        let when = try #require(found.first { $0.kind == .date })
        #expect(when.date == date(2025, 5, 5))
        #expect(!when.isVague)
    }

    @Test("„Heute“ und bloße Wochentage im Transkript sind kein Termin")
    func relativeDatesInTranscriptAreNoise() {
        let found = extract(lines: [
            "Heute sprechen wir über Datenschutz.",
            "Am Montag war ich müde, und morgen geht es weiter.",
            "Um 18 Uhr ist Feierabend.",
        ], published: date(2026, 3, 1))
        #expect(!found.contains { $0.kind == .date })
    }

    @Test("„Heute um 20 Uhr“ in den Shownotes meint den Tag der Folge")
    func relativeDateInShownotes() throws {
        let published = date(2026, 3, 1, 9)
        let found = extract(shownotes: "Live im Stream heute um 20 Uhr.", published: published)
        let when = try #require(found.first { $0.kind == .date })
        #expect(when.date == date(2026, 3, 1, 20))
        #expect(when.hasTime)
        #expect(when.isVague)
    }

    @Test("Derselbe Tag wird ein Termin, die Uhrzeit gewinnt")
    func sameDayMerges() throws {
        let found = extract(shownotes: "Workshop am 12. November 2026 um 18 Uhr.",
                            lines: ["Wir sehen uns am 12. November."], published: date(2026, 10, 1))
        let dates = found.filter { $0.kind == .date }
        #expect(dates.count == 1)
        let when = try #require(dates.first)
        #expect(when.hasTime)
        #expect(!when.isVague)
        #expect(when.occurrences.count == 2)
    }

    // MARK: - Zusammenführen und Rauschen

    @Test("Derselbe Link aus Shownotes und Transkript wird eine Nennung mit zwei Stellen")
    func linkDeduplication() throws {
        let found = extract(shownotes: "<p>Mehr: https://www.example.org/ki-arbeit/</p>",
                            lines: ["Einleitung.", "Alles steht auf example.org/ki-arbeit, schaut vorbei."])
        let links = found.filter { $0.kind == .link }
        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.occurrences.map(\.origin) == [.shownotes, .transcript])
        #expect(link.firstTime == MediaTime(milliseconds: 30_000))
    }

    @Test("Die eigene Domain des Podcasts zählt nur aus den Shownotes")
    func ownDomain() {
        let found = extract(shownotes: "<p>Impressum: https://meinpodcast.de/impressum</p>",
                            lines: ["Mehr auf meinpodcast.de/folge-12 und auf example.org."],
                            ownHosts: ["feeds.meinpodcast.de"])
        let links = found.filter { $0.kind == .link }.map(\.normalized)
        #expect(links.contains("meinpodcast.de/impressum"))
        #expect(!links.contains("meinpodcast.de/folge-12"))
        #expect(links.contains("example.org"))
    }

    @Test("Mediendateien sind keine Links")
    func mediaFilesAreNotLinks() {
        let found = extract(shownotes: "Cover: https://cdn.example.org/cover.jpg Audio: https://cdn.example.org/folge.mp3")
        #expect(!found.contains { $0.kind == .link })
    }

    @Test("Telefonnummer im Transkript nur mit einem Hinweiswort")
    func phoneNeedsCue() {
        #expect(!extract(lines: ["Wir hatten 030 1234567 Zuhörer im Jahr."]).contains { $0.kind == .phone })
        #expect(extract(lines: ["Ruft uns an unter 030 1234567."]).contains { $0.kind == .phone })
    }

    @Test("Jede Art hat eine Obergrenze")
    func limits() {
        let notes = (1...45).map { "https://example\($0).org/seite" }.joined(separator: "\n")
        let links = extract(shownotes: notes).filter { $0.kind == .link }
        #expect(links.count == MentionExtractor.limits[.link])
        #expect(links.first?.normalized == "example1.org/seite")
    }

    // MARK: - Namen

    @Test("Volle Namen werden erkannt, ein Nachname allein kommt zum vollen Namen")
    func namesGerman() {
        let found = extract(lines: [
            "Angela Merkel sprach mit Olaf Scholz in Berlin über die Lage.",
            "Später sagte Merkel, dass Berlin wichtig bleibt.",
        ])
        let people = found.filter { $0.kind == .person }
        #expect(people.contains { $0.display == "Angela Merkel" })
        #expect(people.contains { $0.display == "Olaf Scholz" })
        #expect(!people.contains { $0.normalized == "merkel" })
        #expect(!people.contains { $0.display == "Deutsche Bahn" })
    }

    @Test("Englische Namen, Organisationen und Orte")
    func namesEnglish() {
        let found = extract(lines: ["Sundar Pichai from Google met Satya Nadella in Seattle last week."],
                            language: "en_US")
        let people = found.filter { $0.kind == .person }.map(\.display)
        #expect(people.contains("Sundar Pichai"))
        #expect(people.contains("Satya Nadella"))
    }

    @Test("Hauptwörter werden keine Personen")
    func commonNounsAreNotPeople() {
        let found = extract(lines: [
            "Viele Unternehmen testen KI-Assistenten zuerst im Kundenservice.",
            "Modelle auf dem Gerät verarbeiten Text lokal.",
            "Modelle sind schnell. Studie zeigt: Teams arbeiten schneller.",
            "Die Deutsche Bahn fährt heute pünktlich.",
        ])
        let people = found.filter { $0.kind == .person }.map(\.display)
        #expect(!people.contains("Modelle"))
        #expect(!people.contains("Studie"))
        #expect(!people.contains("Deutsche Bahn"))
    }

    // MARK: - Fragen im Chat

    @Test("Fragen nach Nennungen werden erkannt")
    func questionKinds() {
        #expect(MentionQuestion.kinds(in: "Welche Links werden genannt?") == [.link])
        #expect(MentionQuestion.kinds(in: "Welche Termine kommen vor?") == [.date])
        #expect(MentionQuestion.kinds(in: "Welche Links und Adressen werden gennnt?") == [.link, .address])
        #expect(MentionQuestion.kinds(in: "Gibt es eine Telefonnummer?") == [.phone])
        #expect(MentionQuestion.kinds(in: "Welche E-Mail-Adressen gibt es?") == [.email])
        #expect(MentionQuestion.kinds(in: "Which people are mentioned?") == [.person])
        #expect(MentionQuestion.kinds(in: "What links are mentioned in this episode?") == [.link])
        #expect(MentionQuestion.kinds(in: "Welche Orte kommen vor?") == [.place])
        #expect(MentionQuestion.kinds(in: "Wer wird erwähnt?") == [.person])
        #expect(MentionQuestion.kinds(in: "Links?") == [.link])
        #expect(MentionQuestion.kinds(in: "Any phone numbers?") == [.phone])
        #expect(MentionQuestion.kinds(in: "Kommt in der Folge eine Adresse vor?") == [.address])
        #expect(MentionQuestion.kinds(in: "Which dates come up?") == [.date])
    }

    @Test("Fragen an den Inhalt bleiben beim Sprachmodell")
    func questionContent() {
        #expect(MentionQuestion.kinds(in: "Welche Zahlen und Namen werden genannt?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Welche Firmen investieren gerade in KI?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Worum geht es in dieser Folge?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Was sagt sie über Datenschutz?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Warum ist der Link wichtig?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Welche Daten verlassen das Telefon nicht?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Welches Land hat die strengsten Regeln für KI?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Wer war vor Ort dabei?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Welche Firma war vor allem betroffen?").isEmpty)
        #expect(MentionQuestion.kinds(in: "What appears to be the problem with the link?").isEmpty)
        #expect(MentionQuestion.kinds(in: "Is there any link between sleep and memory?").isEmpty)
    }

    // MARK: - Ausgabe

    @Test("Einzahl und Mehrzahl kommen aus dem Katalog")
    func counted() {
        #expect(Mention.Kind.link.counted(1) == TestLanguage.pick(de: "1 Link", en: "1 link"))
        #expect(Mention.Kind.link.counted(3) == TestLanguage.pick(de: "3 Links", en: "3 links"))
        #expect(Mention.Kind.address.counted(1) == TestLanguage.pick(de: "1 Adresse", en: "1 address"))
        #expect(Mention.Kind.person.counted(2) == TestLanguage.pick(de: "2 Personen", en: "2 people"))
    }

    @Test("Zusammenfassung und Kontext für das Modell")
    func summaryAndContext() throws {
        let found = extract(shownotes: "Workshop am 12. November 2026 um 18 Uhr, Anmeldung unter https://example.org/workshop",
                            lines: ["Die Anmeldung läuft über example punkt org slash workshop."],
                            published: date(2026, 10, 1))
        let summary = try #require(MentionSummary.text(found, kinds: [.link, .date]))
        #expect(summary.contains(Mention.Kind.link.counted(1)))
        #expect(summary.contains(Mention.Kind.date.counted(1)))
        let context = try #require(MentionSummary.modelContext(found))
        #expect(context.hasPrefix("Erwähnt: Links: example.org/workshop (0:00)"))
        #expect(context.contains("Termine: 12.11.2026 18:00"))
    }

    @Test("Export der Folge führt die Nennungen mit Zeitmarken")
    func dossierExport() {
        let found = extract(shownotes: "Mehr unter https://example.org/workshop",
                            lines: ["Einleitung.", "Die Anmeldung läuft über example punkt org slash workshop."])
        let markdown = EpisodeDossierExporter().markdown(
            EpisodeDossier(title: "Folge", sourceTitle: "Podcast", mentions: found), includeTranscript: false)
        #expect(markdown.contains("## " + TestLanguage.pick(de: "Erwähnt", en: "Mentioned")))
        #expect(markdown.contains("### Links"))
        #expect(markdown.contains("(https://example.org/workshop)"))
        #expect(markdown.contains("`0:30`"))
    }

    @Test("Kalenderdatei: ganztägig, maskiert, mit CRLF")
    func calendarFile() {
        let text = CalendarFile.event(title: "Workshop, Berlin; mit Anmeldung", start: date(2026, 11, 12),
                                      allDay: true, notes: "Zeile eins\nZeile zwei",
                                      url: URL(string: "https://example.org/workshop"))
        #expect(text.contains("DTSTART;VALUE=DATE:20261112\r\n"))
        #expect(text.contains("DTEND;VALUE=DATE:20261113\r\n"))
        #expect(text.contains("SUMMARY:Workshop\\, Berlin\\; mit Anmeldung"))
        #expect(text.contains("DESCRIPTION:Zeile eins\\nZeile zwei"))
        #expect(text.hasPrefix("BEGIN:VCALENDAR\r\n"))
        #expect(text.hasSuffix("END:VCALENDAR\r\n"))
    }

    @Test("Nennungen überstehen Speichern und Laden")
    func codable() throws {
        let found = extract(shownotes: "Mehr unter https://example.org/workshop am 12. November 2026.",
                            published: date(2026, 10, 1))
        let data = try JSONEncoder().encode(found)
        let decoded = try JSONDecoder().decode([Mention].self, from: data)
        #expect(decoded == found)
    }
}
