//
//  SharedLinks.swift
//  PodcastAIShareInbox
//
//  Welcher Link in einer Freigabe steckt und was er meint, ohne Netz.
//
//  Die Regeln sind dieselben wie beim Einfügen im Blatt „Hinzufügen“:
//  `SourceResolver` für Feeds, Audiodateien und YouTube, `EpisodeLinks` für
//  Apple Podcasts, `SocialLinks` für Beiträge aus sozialen Netzen. Hier
//  entsteht keine zweite Fassung davon. Die Erweiterung zeigt damit nur an,
//  was sie erkannt hat; was daraus wird, entscheidet die App.
//

import Foundation
import PodcastAICore
import PodcastAISources

/// Was ein geteilter Link meint.
public enum SharedLinkKind: Equatable, Sendable {
    case applePodcastEpisode
    case applePodcast
    case spotify
    case youTubeVideo
    case youTubeChannel
    case youTubePlaylist
    case socialPost(SocialPlatform)
    case socialProfile(SocialPlatform)
    /// Eine einzelne Audiodatei im Netz.
    case audioFile
    case podcastFeed
    /// Eine Webseite, hinter der die App einen Feed oder eine Folge sucht.
    case webPage
}

public enum SharedLinks {

    /// Längere Adressen nimmt der Eingang nicht an.
    public static let maximumLength = 4096

    /// Die Adresse aus einer Freigabe. Viele Apps teilen einen Satz mit dem
    /// Link am Ende, andere nur den Link. Genommen wird der erste Link, den
    /// `SourceResolver` annimmt; Dateien auf dem Gerät zählen nicht.
    public static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let whole = accepted(trimmed) { return whole }
        for word in trimmed.split(whereSeparator: \.isWhitespace) where word.contains("://") {
            if let url = accepted(String(word)) { return url }
        }
        return nil
    }

    /// Nimmt eine Adresse an, wenn sie kurz genug ist und `SourceResolver`
    /// sie als Link im Netz liest.
    public static func accepted(_ candidate: String) -> URL? {
        guard candidate.count <= maximumLength, candidate.contains("://"),
              !candidate.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme != "file", url.host()?.isEmpty == false else { return nil }
        switch try? SourceResolver().resolve(candidate) {
        case .localFile?, nil: return nil
        default: return url
        }
    }

    /// Ordnet einen Link ein, in derselben Reihenfolge wie das Blatt
    /// „Hinzufügen“: erst soziale Netze, dann Apple Podcasts und Spotify,
    /// dann die Regeln von `SourceResolver`.
    public static func classify(_ url: URL) -> SharedLinkKind {
        switch SocialLinks.classify(url) {
        case .post(let platform, _)?: return .socialPost(platform)
        case .profile(let platform, _)?: return .socialProfile(platform)
        case nil: break
        }
        if EpisodeLinks.appleEpisode(in: url) != nil { return .applePodcastEpisode }
        if EpisodeLinks.isApplePodcasts(url) { return .applePodcast }
        let host = url.host()?.lowercased() ?? ""
        if host.hasSuffix("spotify.com") || host == "spotify.link" { return .spotify }
        switch try? SourceResolver().resolve(url.absoluteString) {
        case .youTubeVideo?: return .youTubeVideo
        case .youTubeChannel?, .youTubeChannelPage?: return .youTubeChannel
        case .youTubePlaylist?: return .youTubePlaylist
        case .audioFile?: return .audioFile
        case .podcastFeed?: return .podcastFeed
        case .webPageNeedingDiscovery?, .localFile?, nil: return .webPage
        }
    }
}
