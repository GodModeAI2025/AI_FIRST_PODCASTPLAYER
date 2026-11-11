//
//  EpisodeIdentity.swift
//  PodcastAISources
//
//  Die Kennung einer Folge aus dem Feed.
//
//  iPhone, iPad und Mac legen Folgen mit ihr an. Uhr und Fernseher lesen
//  diese Folgen aus iCloud und dazu frisch aus dem Feed. Beide Wege müssen
//  für dieselbe Folge dieselbe Kennung ergeben, sonst steht sie auf Uhr und
//  Fernseher doppelt in der Liste, und eine am iPhone gelöschte Folge kommt
//  aus dem Feed zurück. Die Regel steht deshalb hier, wo die iOS-App und der
//  Player sie beide erreichen. Eine zweite Fassung an anderer Stelle darf es
//  nicht geben.
//
//  Wer sie ändert, gibt jeder vorhandenen Folge eine neue Kennung.
//

import Foundation
import PodcastAICore

extension ParsedItem {

    /// Der Schlüssel der Folge in ihrem Podcast: die Feed-GUID, sonst die
    /// Audioadresse, sonst der Titel. Der Titel ist der letzte Ausweg: er
    /// ändert sich, und zwei Folgen können gleich heißen.
    public var episodeKey: String {
        guid ?? audioURL?.absoluteString ?? title
    }

    /// Die Kennung der Folge: Podcast und Schlüssel.
    public func episodeID(in sourceID: SourceID) -> EpisodeID {
        EpisodeID(stable: "\(sourceID.rawValue)|\(episodeKey)")
    }
}
