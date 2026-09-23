//
//  MentionQuestion.swift
//  PodcastAIKnowledge
//
//  Erkennt Fragen nach Nennungen: „Welche Links werden genannt?“,
//  „Welche Termine kommen vor?“, „Which people are mentioned?“.
//
//  Solche Fragen beantwortet die App aus den erkannten Nennungen, ohne
//  Sprachmodell und damit auch ohne Apple Intelligence. Die Erkennung ist
//  bewusst eng: Es braucht ein Wort für die Art und eines, das nach einer
//  Liste fragt. Bei Namen muss die Frage ausdrücklich nach Nennungen fragen,
//  denn „Welche Firmen investieren in KI?“ ist eine Frage an den Inhalt.
//  Wer nach Zahlen, Fakten oder Aussagen fragt, bekommt die gewohnte Antwort.
//

import Foundation

public enum MentionQuestion {

    /// Nach welchen Arten fragt die Frage? Leer, wenn es keine Frage nach Nennungen ist.
    public static func kinds(in question: String) -> [Mention.Kind] {
        let text = question.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                    locale: nil)
        // Erst in Wörter zerlegen, dann zusammengesetzte Wörter verbinden,
        // sonst wird aus „E-Mail-Adresse“ eine Adresse. Auf der Wortfolge,
        // nicht im Text: „welche mails“ bleibt zwei Wörter.
        let words = merged(text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        guard !words.isEmpty else { return [] }
        let vocabulary = Set(words)
        guard vocabulary.isDisjoint(with: blockers) else { return [] }

        var kinds: Set<Mention.Kind> = []
        for word in words {
            for (kind, keys) in keywords where keys.contains(word) { kinds.insert(kind) }
        }
        let mentionVerb = words.contains(where: isMentionVerb) || asksWhatComesUp(words)
        // „Wer wird genannt?“
        if kinds.isEmpty, mentionVerb, !vocabulary.isDisjoint(with: ["wer", "who"]) { kinds.insert(.person) }
        guard !kinds.isEmpty else { return [] }

        let listing = !vocabulary.isDisjoint(with: listingWords)
        let short = words.count <= 3
        // „Which events shaped AI?“ fragt nach dem Inhalt. Steht für Termine
        // nur ein solches Wort da, gilt dieselbe Vorsicht wie bei Namen.
        let onlyVagueDates = vocabulary.isDisjoint(with: keywords[.date, default: []].subtracting(vagueDateWords))
        return kinds.filter { kind in
            kind.isName || (kind == .date && onlyVagueDates)
                ? mentionVerb || short || (listing && words.count <= 4)
                : mentionVerb || listing || short
        }.sorted()
    }

    /// Verbindet Wortfolgen wie „e mail adressen“ oder „phone numbers“ zu
    /// einem Wort, die längste Folge zuerst.
    private static func merged(_ words: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < words.count {
            let match = compounds.first { entry in
                index + entry.parts.count <= words.count
                    && Array(words[index..<index + entry.parts.count]) == entry.parts
            }
            if let match {
                result.append(match.word)
                index += match.parts.count
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result
    }

    /// Wortfolgen, längste zuerst. Bindestriche trennen schon beim Zerlegen,
    /// „E-Mail-Adresse“ kommt hier als „e mail adresse“ an.
    private static let compounds: [(parts: [String], word: String)] = [
        (["e", "mail", "adressen"], "email"), (["e", "mail", "adresse"], "email"),
        (["e", "mail", "addresses"], "email"), (["e", "mail", "address"], "email"),
        (["email", "adressen"], "email"), (["email", "adresse"], "email"),
        (["email", "addresses"], "email"), (["email", "address"], "email"),
        (["mail", "adressen"], "email"), (["mail", "adresse"], "email"),
        (["mail", "addresses"], "email"), (["mail", "address"], "email"),
        (["e", "mails"], "emails"), (["e", "mail"], "email"),
        (["web", "adressen"], "links"), (["web", "adresse"], "links"),
        (["internet", "adressen"], "links"), (["internet", "adresse"], "links"),
        (["web", "addresses"], "links"), (["web", "address"], "links"),
        (["telephone", "numbers"], "phone"), (["telephone", "number"], "phone"),
        (["phone", "numbers"], "phone"), (["phone", "number"], "phone"),
    ]

    /// Wörter für Termine, die auch im Inhalt oft vorkommen.
    private static let vagueDateWords: Set<String> = [
        "veranstaltung", "veranstaltungen", "event", "events", "kalender", "calendar",
    ]

    private static let keywords: [Mention.Kind: Set<String>] = [
        .link: ["link", "links", "url", "urls", "webseite", "webseiten", "website", "websites", "homepage",
                "homepages", "weblink", "weblinks", "domain", "domains", "webadresse", "webadressen",
                "internetadresse", "internetadressen"],
        .date: ["termin", "termine", "terminen", "datum", "veranstaltung", "veranstaltungen", "event", "events",
                "date", "dates", "appointment", "appointments", "deadline", "deadlines", "frist", "fristen",
                "kalender", "calendar"],
        .address: ["adresse", "adressen", "anschrift", "anschriften", "address", "addresses"],
        .phone: ["telefonnummer", "telefonnummern", "rufnummer", "rufnummern", "handynummer",
                 "phone", "phones", "telephone", "hotline"],
        .email: ["email", "emails", "mail", "mails", "mailadresse", "mailadressen", "emailadresse",
                 "emailadressen"],
        .person: ["person", "personen", "leute", "namen", "people", "persons", "names", "gast", "gaste",
                  "guest", "guests"],
        .organization: ["organisation", "organisationen", "organization", "organizations", "organisations",
                        "firma", "firmen", "unternehmen", "company", "companies", "institution", "institutionen",
                        "institutions", "namen", "names"],
        .place: ["ort", "orte", "orten", "stadt", "stadte", "land", "lander", "place", "places", "city", "cities",
                 "country", "countries", "location", "locations", "region", "regionen", "regions"],
    ]

    /// Wörter, die nach einer Aufzählung fragen. Kein „what“: „What is
    /// the link between …“ fragt nach einem Zusammenhang, nicht nach Links.
    private static let listingWords: Set<String> = [
        "welche", "welcher", "welches", "welchen", "gibt", "gib", "nenn", "nenne", "nennt", "liste", "list",
        "zeig", "zeige", "alle", "which", "any", "show", "all", "wo", "where", "give", "tell",
        "verrat", "verrate",
    ]

    /// Wörter, die ausdrücklich nach Nennungen fragen.
    private static func isMentionVerb(_ word: String) -> Bool {
        if mentionVerbs.contains(word) { return true }
        // „genannt“, auch vertippt wie „gennant“ oder „gennnt“.
        return word.hasPrefix("gen") && word.hasSuffix("nt") && (6...8).contains(word.count)
    }

    private static let mentionVerbs: Set<String> = [
        "genannt", "erwahnt", "erwaehnt", "vorkommen", "vorkommt", "vorgekommen", "angesprochen",
        "verlinkt", "mentioned", "named", "referenced", "cited", "linked",
    ]

    /// „kommen vor“, „Kommt ein Link in der Folge vor?“. Ein „vor“ allein
    /// zählt nicht, sonst fragte „Wer war vor Ort dabei?“ nach Orten.
    private static func asksWhatComesUp(_ words: [String]) -> Bool {
        let comes: Set<String> = ["kommt", "kommen", "kam", "kamen"]
        if zip(words, words.dropFirst()).contains(where: { comes.contains($0) && $1 == "vor" }) { return true }
        return words.last == "vor" && !comes.isDisjoint(with: words)
    }

    /// Wer danach fragt, will eine Antwort aus dem Inhalt, keine Liste.
    private static let blockers: Set<String> = [
        "zahl", "zahlen", "statistik", "statistiken", "fakt", "fakten", "fact", "facts", "aussage", "aussagen",
        "claim", "claims", "argument", "argumente", "arguments", "meinung", "meinungen", "opinion", "opinions",
        "thesen", "warum", "wieso", "weshalb", "why", "sagt", "sagen", "gesagt", "said", "says", "say",
        "denkt", "denken", "think", "thinks", "erklart", "erklaert", "explain", "explains", "bedeutet", "means",
        "zusammenfassung", "summary", "numbers", "figures", "between", "zwischen", "zusammenhang",
        "connection", "relationship", "beziehung",
    ]
}
