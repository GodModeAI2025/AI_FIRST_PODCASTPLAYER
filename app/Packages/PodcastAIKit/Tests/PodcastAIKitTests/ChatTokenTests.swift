//
//  ChatTokenTests.swift
//
//  Eingrenzung im Eingabefeld des Chats: Zeitangaben und Namen erkennen,
//  Tokens setzen und entfernen, und wie der Code damit Folgen und Stellen
//  auswählt, bevor ein Modell etwas sieht. Dazu die letzten Fragen.
//

import Testing
import Foundation
@testable import PodcastAIKit

@Suite("Tokens im Chat")
struct ChatTokenTests {

    /// Samstag, 26. September 2026, mittags in Berlin.
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    var now: Date { day(2026, 9, 26).addingTimeInterval(12 * 3_600) }
    var parser: ChatTokenParser { ChatTokenParser(now: now, calendar: calendar) }

    func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    let lage = SourceID(stable: "lage-der-nation")
    let logbuch = SourceID(stable: "logbuch")
    let datenschutz = InterestID(stable: "tag|datenschutz")
    let wahlFolge = EpisodeID(stable: "folge-wahl")

    var catalog: ChatTokenCatalog {
        ChatTokenCatalog(
            sources: [
                .init(token: .source(lage), name: "Lage der Nation"),
                .init(token: .source(logbuch), name: "Logbuch:Netzpolitik"),
            ],
            tags: [.init(token: .tag(datenschutz), name: "Datenschutz", aliases: ["Privatsphäre"])],
            episodes: [.init(token: .episode(wahlFolge), name: "LdN 412: Wahl in Sachsen")])
    }

    // MARK: - Zeitangaben

    @Test("„seit 1. Juni“ beginnt am 1. Juni dieses Jahres, 0 Uhr")
    func sinceFirstOfJune() {
        #expect(parser.dateToken(in: "seit 1. Juni") == .since(day(2026, 6, 1)))
        #expect(parser.dateToken(in: "Seit dem 1. Juni") == .since(day(2026, 6, 1)))
        #expect(parser.dateToken(in: "seit 1.6.") == .since(day(2026, 6, 1)))
        #expect(parser.dateToken(in: "ab 01.06.2025") == .since(day(2025, 6, 1)))
        #expect(parser.dateToken(in: "since June 1st") == .since(day(2026, 6, 1)))
        #expect(parser.dateToken(in: "since 1 June 2024") == .since(day(2024, 6, 1)))
        #expect(parser.dateToken(in: "seit 2026-06-01") == .since(day(2026, 6, 1)))
    }

    @Test("Ohne Jahr gilt das letzte Mal, dass der Tag war")
    func yearRule() {
        // Der 1. Dezember 2026 kommt erst noch, gemeint ist 2025.
        #expect(parser.dateToken(in: "seit 1. Dezember") == .since(day(2025, 12, 1)))
        // Heute zählt noch zu diesem Jahr.
        #expect(parser.dateToken(in: "seit 26. September") == .since(day(2026, 9, 26)))
        #expect(parser.dateToken(in: "seit 27. September") == .since(day(2025, 9, 27)))
        // Den 29. Februar gab es zuletzt 2024.
        #expect(parser.dateToken(in: "seit 29. Februar") == .since(day(2024, 2, 29)))
    }

    @Test("Ein Monat ohne Tag: „seit“ ab dem Ersten, „bis“ mit dem ganzen Monat")
    func monthOnly() {
        #expect(parser.dateToken(in: "seit Juni") == .since(day(2026, 6, 1)))
        #expect(parser.dateToken(in: "seit März 2025") == .since(day(2025, 3, 1)))
        #expect(parser.dateToken(in: "bis Juni") == .before(day(2026, 7, 1)))
    }

    @Test("„bis 30. Juni“ schließt den 30. ein")
    func untilIncludesTheDay() {
        #expect(parser.dateToken(in: "bis 30. Juni") == .before(day(2026, 7, 1)))
        #expect(parser.dateToken(in: "bis zum 30.6.26") == .before(day(2026, 7, 1)))
        #expect(parser.dateToken(in: "until July 15, 2026") == .before(day(2026, 7, 16)))
    }

    @Test("„letzte Woche“ ist der Zeitraum aus dem Menü")
    func relativePeriods() {
        #expect(parser.dateToken(in: "letzte Woche") == .period(.lastWeek))
        #expect(parser.dateToken(in: "in den letzten 7 Tagen") == .period(.lastWeek))
        #expect(parser.dateToken(in: "im letzten Monat") == .period(.lastMonth))
        #expect(parser.dateToken(in: "in den letzten 30 Tagen") == .period(.lastMonth))
        #expect(parser.dateToken(in: "last week") == .period(.lastWeek))
        #expect(parser.dateToken(in: "over the past month") == .period(.lastMonth))
    }

    @Test("Kein Tag, kein Token")
    func noFalseDates() {
        #expect(parser.dateToken(in: "seit 31. Juni") == nil)
        #expect(parser.dateToken(in: "seit 1.13.") == nil)
        #expect(parser.dateToken(in: "ab und zu") == nil)
        #expect(parser.dateToken(in: "von Apple bis Google") == nil)
        #expect(parser.dateToken(in: "Was sagt der Gast über die Woche?") == nil)
        #expect(parser.dateToken(in: "seit dem Start") == nil)
    }

    @Test("Angenommen, fällt die Zeitangabe aus der Frage")
    func remainingTextWithoutDate() {
        let since = parser.suggestions(for: "Was wurde seit 1. Juni über KI gesagt?", catalog: catalog)
        #expect(since.first?.token == .since(day(2026, 6, 1)))
        #expect(since.first?.remainingText == "Was wurde über KI gesagt?")

        let week = parser.suggestions(for: "Was wurde in der letzten Woche gesagt?", catalog: catalog)
        #expect(week.first?.token == .period(.lastWeek))
        #expect(week.first?.remainingText == "Was wurde gesagt?")

        let atEnd = parser.suggestions(for: "Was wurde gesagt seit Juni?", catalog: catalog)
        #expect(atEnd.first?.remainingText == "Was wurde gesagt?")
    }

    @Test("Zwei Zeitangaben ergeben zwei Vorschläge")
    func twoDates() {
        let tokens = parser.dateMatches(in: "vom 1. Juni bis 30. Juni").map(\.token)
        #expect(tokens == [.since(day(2026, 6, 1)), .before(day(2026, 7, 1))])
    }

    // MARK: - Namen

    @Test("„Podcast:“ sucht unter den Abos")
    func podcastPrefix() {
        let found = parser.suggestions(for: "Podcast: lage", catalog: catalog)
        #expect(found.map(\.token) == [.source(lage)])
        #expect(found.first?.name == "Lage der Nation")
        #expect(found.first?.remainingText == "")

        // Ohne Suchwort alle Abos.
        #expect(parser.suggestions(for: "Podcast:", catalog: catalog).count == 2)
        // Die Frage davor bleibt stehen.
        let withQuestion = parser.suggestions(for: "Was ist neu? podcast:netz", catalog: catalog)
        #expect(withQuestion.map(\.token) == [.source(logbuch)])
        #expect(withQuestion.first?.remainingText == "Was ist neu?")
    }

    @Test("„#“ und „Tag:“ suchen unter den Tags, auch in anderen Schreibweisen")
    func tagPrefix() {
        #expect(parser.suggestions(for: "#daten", catalog: catalog).map(\.token) == [.tag(datenschutz)])
        #expect(parser.suggestions(for: "Tag: privat", catalog: catalog).map(\.token) == [.tag(datenschutz)])
        #expect(parser.suggestions(for: "#wetter", catalog: catalog).isEmpty)
    }

    @Test("„Folge:“ sucht Folgen, auch mitten im Titel")
    func episodePrefix() {
        let found = parser.suggestions(for: "Folge: sachsen", catalog: catalog)
        #expect(found.map(\.token) == [.episode(wahlFolge)])
    }

    @Test("Ein Name am Ende wird ohne Einleitung vorgeschlagen")
    func trailingName() {
        let found = parser.suggestions(for: "Was sagt Lage der", catalog: catalog)
        #expect(found.map(\.token) == [.source(lage)])
        #expect(found.first?.remainingText == "Was sagt")
        #expect(parser.suggestions(for: "Was sagt Dat", catalog: catalog).map(\.token) == [.tag(datenschutz)])
        // Zu kurz, schon zu Ende getippt oder kein Anfang eines Namens.
        #expect(parser.suggestions(for: "La", catalog: catalog).isEmpty)
        #expect(parser.suggestions(for: "Was sagt Lage ", catalog: catalog).isEmpty)
        #expect(parser.suggestions(for: "Nation", catalog: catalog).isEmpty)
    }

    @Test("Was schon eingegrenzt ist, wird nicht noch einmal vorgeschlagen")
    func excludesChosen() {
        let filter = LibraryFilter(sourceID: lage)
        #expect(parser.suggestions(for: "Podcast: lage", catalog: catalog, excluding: filter).isEmpty)
        let week = LibraryFilter(period: .lastWeek)
        #expect(parser.suggestions(for: "letzte Woche", catalog: catalog, excluding: week).isEmpty)
    }

    // MARK: - Bereich aus Tokens

    @Test("Tokens setzen und entfernen")
    func addingAndRemoving() {
        var filter = LibraryFilter()
        filter = filter.adding(.source(lage)).adding(.source(logbuch)).adding(.tag(datenschutz))
        #expect(filter.sourceIDs == [lage, logbuch])
        #expect(filter.sourceID == nil, "Bei zwei Podcasts zeigt das Menü keinen einzelnen")
        #expect(!filter.isUnrestricted)
        #expect(filter.tokens.map(\.kind) == [.source, .source, .tag])

        // „seit“ ersetzt den Zeitraum aus dem Menü und umgekehrt.
        filter = filter.adding(.period(.lastWeek))
        filter = filter.adding(.since(day(2026, 6, 1)))
        #expect(filter.period == .all)
        #expect(filter.since == day(2026, 6, 1))
        filter = filter.adding(.period(.lastMonth))
        #expect(filter.since == nil)

        for token in filter.tokens { filter = filter.removing(token) }
        #expect(filter.isUnrestricted)
        #expect(filter == LibraryFilter())
    }

    @Test("Die Reihenfolge der Tokens ändert den Bereich nicht")
    func orderDoesNotMatter() {
        let first = LibraryFilter().adding(.source(lage)).adding(.source(logbuch)).adding(.episode(wahlFolge))
        let second = LibraryFilter().adding(.episode(wahlFolge)).adding(.source(logbuch)).adding(.source(lage))
        #expect(ChatScope.library(first) == ChatScope.library(second))
    }

    @Test("Seit und bis grenzen das Erscheinungsdatum ein")
    func dateBounds() {
        let filter = LibraryFilter(sourceIDs: [], since: day(2026, 6, 1), before: day(2026, 7, 1))
        #expect(filter.admits(sourceID: lage, publishedAt: day(2026, 6, 1), now: now))
        #expect(filter.admits(sourceID: lage, publishedAt: day(2026, 6, 30).addingTimeInterval(23 * 3_600), now: now))
        #expect(!filter.admits(sourceID: lage, publishedAt: day(2026, 7, 1), now: now))
        #expect(!filter.admits(sourceID: lage, publishedAt: day(2026, 5, 31), now: now))
        #expect(!filter.admits(sourceID: lage, publishedAt: nil, now: now))
    }

    @Test("Zeit-Tokens nennen den Tag, den der Code verstanden hat")
    func dateLabels() throws {
        let since = try #require(ChatToken.since(day(2026, 6, 1)).dateLabel)
        #expect(since.hasPrefix(TestLanguage.pick(de: "seit ", en: "since ")))
        #expect(since.contains("2026"))
        // „bis 30. Juni“ ist als 1. Juli gespeichert und heißt trotzdem 30.
        let until = try #require(ChatToken.before(day(2026, 7, 1)).dateLabel)
        #expect(until.hasPrefix(TestLanguage.pick(de: "bis ", en: "until ")))
        #expect(until.contains("30"))
        #expect(ChatToken.period(.lastWeek).dateLabel == LibraryFilter.Period.lastWeek.label)
        #expect(ChatToken.source(lage).dateLabel == nil)

        let scope = ChatScope.library(LibraryFilter(sourceIDs: [lage, logbuch], tagIDs: [datenschutz]))
        #expect(scope.label.contains("2"))
        #expect(scope.label.contains(" · "))
    }

    @Test("Mehrere Podcasts: einer davon reicht")
    func severalSources() {
        let filter = LibraryFilter(sourceIDs: [lage, logbuch])
        #expect(filter.admits(sourceID: lage, publishedAt: nil, now: now))
        #expect(filter.admits(sourceID: logbuch, publishedAt: nil, now: now))
        #expect(!filter.admits(sourceID: SourceID(stable: "andere"), publishedAt: nil, now: now))
    }

    // MARK: - Auswahl vor dem Modell

    func episode(_ id: EpisodeID, source: SourceID, published: Date?) -> Episode {
        Episode(id: id, sourceID: source, title: id.rawValue, publishedAt: published)
    }

    func passage(_ key: String, episode: EpisodeID, source: SourceID, startSeconds: Int64?,
                 version: String? = nil) -> Evidence {
        Evidence(
            id: EvidenceID(stable: key), mediaVersionID: MediaVersionID(stable: version ?? "m-\(episode.rawValue)"),
            episodeID: episode, sourceID: source, transcriptID: TranscriptID(stable: "t-\(key)"),
            transcriptRevision: .initial,
            range: startSeconds.map {
                MediaTimeRange(start: MediaTime(milliseconds: $0 * 1_000), end: MediaTime(milliseconds: ($0 + 60) * 1_000))
            },
            quotedText: key)
    }

    func chapterTag(_ tag: InterestID, episode: EpisodeID, source: SourceID, from: Int, to: Int,
                    version: String? = nil) -> ChapterTag {
        ChapterTag(
            episodeID: episode, mediaVersionID: MediaVersionID(stable: version ?? "m-\(episode.rawValue)"),
            chapterStartMs: from * 1_000, chapterEndMs: to * 1_000, interestID: tag, normalizedKey: tag.rawValue,
            confidence: 0.9, matchedKnown: true, sourceID: source, publishedAt: nil,
            transcriptRevision: .initial)
    }

    @Test("Gewählte Folgen: nur sie und nur ihre Stellen")
    func episodeNarrowing() {
        let other = EpisodeID(stable: "andere-folge")
        let narrowing = ChatNarrowing(filter: LibraryFilter().adding(.episode(wahlFolge)), now: now)
        #expect(narrowing.narrowsEpisodes)
        #expect(narrowing.admits(episode(wahlFolge, source: lage, published: nil)))
        #expect(!narrowing.admits(episode(other, source: lage, published: nil)))
        let pool = [passage("a", episode: wahlFolge, source: lage, startSeconds: 0),
                    passage("b", episode: other, source: lage, startSeconds: 0)]
        #expect(narrowing.passages(pool).map(\.quotedText) == ["a"])
    }

    @Test("Ein Tag lässt nur Folgen mit einem passenden Kapitel zu, und nur Stellen darin")
    func tagNarrowing() {
        let other = EpisodeID(stable: "ohne-tag")
        let fremdesTag = InterestID(stable: "tag|wetter")
        let tags = [
            chapterTag(datenschutz, episode: wahlFolge, source: lage, from: 120, to: 300),
            // Ein Kapitel-Tag eines anderen Tags zählt nicht.
            chapterTag(fremdesTag, episode: other, source: lage, from: 0, to: 600),
        ]
        let narrowing = ChatNarrowing(filter: LibraryFilter().adding(.tag(datenschutz)), chapterTags: tags, now: now)
        #expect(narrowing.admits(episode(wahlFolge, source: lage, published: nil)))
        #expect(!narrowing.admits(episode(other, source: lage, published: nil)))

        let pool = [
            passage("davor", episode: wahlFolge, source: lage, startSeconds: 60),
            passage("drin", episode: wahlFolge, source: lage, startSeconds: 120),
            passage("auch-drin", episode: wahlFolge, source: lage, startSeconds: 240),
            passage("danach", episode: wahlFolge, source: lage, startSeconds: 300),
            passage("ohne-zeit", episode: wahlFolge, source: lage, startSeconds: nil),
            passage("andere-folge", episode: other, source: lage, startSeconds: 60),
        ]
        #expect(narrowing.passages(pool).map(\.quotedText) == ["drin", "auch-drin"])
    }

    @Test("Kapitelzeiten gelten nur in ihrer Fassung")
    func tagNarrowingPerMediaVersion() {
        // Das Kapitel wurde in der alten Fassung eingeordnet. Die neue hat
        // vorn Werbung, dieselbe Sekunde ist dort eine andere Stelle.
        let tags = [chapterTag(datenschutz, episode: wahlFolge, source: lage, from: 120, to: 300, version: "alt")]
        let narrowing = ChatNarrowing(filter: LibraryFilter().adding(.tag(datenschutz)), chapterTags: tags, now: now)
        // Die Folge bleibt im Bereich, bis die neue Fassung eingeordnet ist.
        #expect(narrowing.admits(episode(wahlFolge, source: lage, published: nil)))
        let pool = [
            passage("alt-drin", episode: wahlFolge, source: lage, startSeconds: 150, version: "alt"),
            passage("neu-gleiche-zeit", episode: wahlFolge, source: lage, startSeconds: 150, version: "neu"),
        ]
        #expect(narrowing.passages(pool).map(\.quotedText) == ["alt-drin"])
    }

    @Test("Ohne Tag bleibt jede Stelle, Podcast und Tage gelten weiter")
    func narrowingWithoutTags() {
        let narrowing = ChatNarrowing(
            filter: LibraryFilter(sourceIDs: [lage], since: day(2026, 6, 1)), now: now)
        #expect(!narrowing.narrowsEpisodes)
        #expect(narrowing.admits(source: lage))
        #expect(!narrowing.admits(source: logbuch))
        #expect(narrowing.admits(episode(wahlFolge, source: lage, published: day(2026, 6, 2))))
        #expect(!narrowing.admits(episode(wahlFolge, source: lage, published: day(2026, 5, 2))))
        #expect(!narrowing.admits(episode(wahlFolge, source: logbuch, published: day(2026, 6, 2))))
        let pool = [passage("a", episode: wahlFolge, source: lage, startSeconds: nil),
                    passage("b", episode: wahlFolge, source: logbuch, startSeconds: 0)]
        #expect(narrowing.passages(pool).map(\.quotedText) == ["a"])
        #expect(ChatNarrowing.unrestricted.passages(pool).count == 2)
    }

    // MARK: - Letzte Fragen

    @Test("Letzte Fragen: neueste zuerst, jede nur einmal, höchstens zehn")
    func recentQuestions() {
        var list: [String] = []
        for number in 1...12 { list = RecentQuestions.inserting("Frage \(number)", into: list) }
        #expect(list.count == 10)
        #expect(list.first == "Frage 12")
        #expect(list.last == "Frage 3")

        list = RecentQuestions.inserting("  frage 5 ", into: list)
        #expect(list.first == "frage 5")
        #expect(list.filter { $0.lowercased() == "frage 5" }.count == 1)
        #expect(list.count == 10)

        #expect(RecentQuestions.inserting("   ", into: list) == list)
    }
}
