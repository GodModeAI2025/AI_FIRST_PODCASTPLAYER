//
//  TagStopwords.swift
//  PodcastAIKnowledge
//
//  Wörter, aus denen kein Tag entsteht.
//
//  Im TestFlight-Feedback standen „bisschen“, „natürlich“ und „unternehmen“
//  als Vorschläge. Solche Wörter kommen in fast jedem Gespräch vor und
//  sagen nichts über das Thema: Artikel, Pronomen, Präpositionen,
//  Bindewörter, Adverbien, Füllwörter und sehr allgemeine Hauptwörter, auf
//  Deutsch und Englisch. Die Namenserkennung hält ein großgeschriebenes
//  „Natürlich“ am Satzanfang auch gern für einen Namen.
//
//  Die Liste greift für Tags, die die App im Inhalt erkennt. Was jemand
//  selbst anlegt, prüft sie nicht.
//

import Foundation

public enum TagStopwords {

    /// Taugt die Bezeichnung nicht als Tag, weil jedes ihrer Wörter ein
    /// Allerweltswort ist? „Natürlich“ und „ein bisschen“ nein, „Die Zeit“
    /// als Name einer Zeitung auch nein, „Federated Learning“ und „iOS 27“ ja.
    /// Ein Wort mit Ziffer ist nie ein Allerweltswort.
    public static func rejects(_ label: String) -> Bool {
        // Kürzel wie „US“, „IT“ oder „EU“ sind klein geschrieben englische
        // Füllwörter, groß geschrieben aber Länder und Fächer.
        let letters = label.filter(\.isLetter)
        if (2...3).contains(letters.count), letters.allSatisfy(\.isUppercase) { return false }
        let words = RelevanceScorer.normalize(label).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            !word.contains(where: \.isNumber) && isStopword(word)
        }
    }

    /// Ein einzelnes, schon normalisiertes Wort (klein, Umlaute erhalten).
    static func isStopword(_ word: String) -> Bool {
        words.contains(word)
            || RelevanceScorer.stopWords.contains(word)
            || PassageRanker.stopwords.contains(word)
            || TopicTagger.generic.contains(word)
    }

    static let words: Set<String> = german.union(english)

    // MARK: - Deutsch

    static let german: Set<String> = [
        // Artikel und Pronomen
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "ich", "du", "er", "sie", "es", "wir", "ihr", "man", "mich", "mir", "dich", "dir", "ihn", "ihm",
        "uns", "euch", "ihnen", "sich", "mein", "dein", "sein", "seine", "seinen", "seinem", "seiner",
        "ihre", "ihren", "ihrem", "ihrer", "unser", "unsere", "euer", "eure", "jemand", "niemand",
        "jeder", "jede", "jedes", "jeden", "alle", "allen", "aller", "beide", "beiden", "manche",
        "einige", "welche", "solche", "dieser", "diese", "dieses", "diesen", "diesem", "jener",
        "selbst", "selber", "nichts", "etwas", "alles", "vieles", "wenig", "wenige", "weniger",
        // Präpositionen und Bindewörter
        "ab", "an", "am", "auf", "aus", "bei", "beim", "bis", "durch", "für", "gegen", "hinter",
        "im", "in", "ins", "mit", "nach", "neben", "ohne", "seit", "trotz", "um", "unter", "über",
        "von", "vom", "vor", "während", "wegen", "zu", "zum", "zur", "zwischen", "und", "oder",
        "aber", "denn", "doch", "sondern", "sowie", "weil", "wenn", "falls", "ob", "als", "wie",
        "dass", "damit", "obwohl", "sobald", "solange", "bevor", "nachdem", "indem", "sodass",
        // Adverbien, Partikeln, Füllwörter
        "bisschen", "natürlich", "eigentlich", "einfach", "genau", "irgendwie", "irgendwann",
        "irgendwo", "quasi", "sozusagen", "halt", "eben", "mal", "ja", "nein", "nee", "schon",
        "wohl", "gar", "ganz", "ziemlich", "echt", "total", "wirklich", "tatsächlich", "letztlich",
        "letztendlich", "grundsätzlich", "eher", "vielleicht", "wahrscheinlich", "sicherlich",
        "sicher", "bestimmt", "eventuell", "möglicherweise", "praktisch", "prinzipiell",
        "jedenfalls", "trotzdem", "dennoch", "allerdings", "außerdem", "zudem", "übrigens",
        "ebenfalls", "ebenso", "jetzt", "gerade", "heute", "morgen", "gestern", "damals", "bald",
        "immer", "nie", "niemals", "oft", "häufig", "manchmal", "selten", "wieder", "weiter",
        "weiterhin", "bereits", "noch", "nur", "auch", "sehr", "mehr", "meist", "meistens",
        "besonders", "ungefähr", "etwa", "fast", "kaum", "hier", "dort", "da", "dann",
        "danach", "davor", "dabei", "dafür", "dagegen", "daher", "darum", "deshalb", "deswegen",
        "somit", "also", "zwar", "sogar", "überhaupt", "insgesamt", "zusammen",
        "gleich", "gleichzeitig", "zuerst", "zunächst", "schließlich", "endlich", "plötzlich",
        "sofort", "ständig", "komplett", "völlig", "richtig", "falsch", "okay", "super", "klar",
        "logisch", "spannend", "interessant", "wichtig", "gut", "besser", "beste", "schlecht",
        "groß", "große", "großen", "klein", "kleine", "neu", "neue", "neuen", "alt", "alte",
        "viel", "viele", "vielen", "andere", "anderen", "anderer", "anders", "verschiedene",
        "gewisse", "bestimmte", "hoffentlich", "leider", "beispielsweise",
        "danke", "hallo", "tschüss", "willkommen",
        // Hilfs- und Allerweltsverben
        "bin", "bist", "ist", "sind", "seid", "war", "waren", "gewesen", "habe", "hast", "hat",
        "haben", "hatte", "hatten", "gehabt", "werde", "wirst", "wird", "werden", "wurde", "wurden",
        "geworden", "kann", "kannst", "können", "konnte", "muss", "müssen", "musste", "soll",
        "sollen", "sollte", "will", "wollen", "wollte", "darf", "dürfen", "mag", "mögen", "möchte",
        "machen", "macht", "gemacht", "sagen", "sagt", "gesagt", "gehen", "geht", "gegangen",
        "kommen", "kommt", "gekommen", "sehen", "sieht", "gesehen", "finden", "findet", "gefunden",
        "denken", "denkt", "glauben", "glaube", "meinen", "meint", "wissen", "weiß", "lassen",
        "stehen", "steht", "bleiben", "bleibt", "geben", "gibt", "nehmen", "nimmt", "reden",
        "sprechen", "spricht", "erzählen", "erzählt", "zeigen", "zeigt", "heißen", "heißt",
        // Allgemeine Hauptwörter ohne eigenes Thema
        "unternehmen", "firma", "firmen", "bereich", "bereiche", "möglichkeit", "form",
        "fall", "fälle", "male", "zeit", "tag", "tage", "woche", "wochen", "monat",
        "monate", "jahr", "mensch", "person", "personen",
        "problem", "probleme", "lösung", "idee", "ideen", "sicht", "blick", "moment", "stelle",
        "stellen", "schritt", "schritte", "ziel", "ziele", "weg", "wege", "rolle",
        "gespräch", "gespräche", "folge", "episode", "podcast", "sendung", "hörer", "hörerinnen",
        "zuhörer", "gast", "gäste", "team", "sachverhalt", "situation", "ergebnis",
        "ergebnisse", "inhalt", "inhalte", "beispiel", "prozess",
        "prozesse", "thema", "themen", "frage", "fragen", "antwort", "ding",
        "dinge", "sache", "sachen", "leute",
    ]

    // MARK: - Englisch

    static let english: Set<String> = [
        // Articles, pronouns, prepositions, conjunctions
        "a", "an", "the", "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us",
        "them", "my", "your", "his", "its", "our", "their", "this", "that", "these", "those",
        "someone", "somebody", "anyone", "everyone", "nobody", "something", "anything",
        "everything", "nothing", "all", "both", "each", "every", "some", "any", "many", "much",
        "few", "other", "others", "another", "such", "of", "in", "on", "at", "to", "for", "from",
        "with", "without", "by", "about", "into", "onto", "over", "under", "between", "through",
        "during", "before", "after", "since", "until", "against", "among", "and", "or", "but",
        "nor", "so", "yet", "because", "although", "though", "while", "whereas", "if", "unless",
        "whether", "than", "as", "like",
        // Adverbs, particles, fillers
        "actually", "basically", "really", "literally", "totally", "definitely", "probably",
        "maybe", "perhaps", "obviously", "clearly", "honestly", "seriously", "simply", "just",
        "quite", "rather", "pretty", "very", "too", "also", "even", "still", "already", "again",
        "always", "never", "often", "sometimes", "usually", "now", "then", "today", "tomorrow",
        "yesterday", "soon", "later", "here", "there", "anyway", "anyways", "however", "therefore",
        "thus", "hence", "instead", "otherwise", "kind", "sort", "somewhat", "almost", "nearly",
        "only", "right", "okay", "yeah", "yes", "no", "well", "sure", "course", "indeed",
        "exactly", "certainly", "especially", "generally", "essentially", "ultimately",
        "important", "interesting", "great", "good", "better", "best", "bad", "big", "small",
        "new", "old", "different", "various", "certain", "welcome", "thanks", "hello",
        // Auxiliary and generic verbs
        "am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do",
        "does", "did", "done", "will", "would", "shall", "should", "can", "could", "may",
        "might", "must", "make", "makes", "made", "say", "says", "said", "go", "goes", "went",
        "get", "gets", "got", "come", "comes", "came", "see", "sees", "saw", "think", "thinks",
        "know", "knows", "want", "wants", "take", "takes", "give", "gives", "talk", "talks",
        "tell", "tells", "show", "shows", "look", "looks", "use", "uses", "need", "needs",
        // Generic nouns
        "company", "companies", "people", "person", "thing", "things", "stuff",
        "way", "ways", "time", "times", "day", "days", "week", "year", "years",
        "part", "parts", "lot", "lots", "bit", "point", "points", "case", "cases", "idea",
        "ideas", "problem", "problems", "question", "questions", "answer", "answers", "example",
        "examples", "topic", "topics", "episode", "episodes", "podcast", "podcasts",
        "guest", "guests", "host", "team", "place", "number", "fact", "facts",
        "process", "content", "moment",
    ]
}
