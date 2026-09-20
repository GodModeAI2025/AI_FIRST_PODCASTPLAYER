//
//  MediaTimeBridge.swift
//  PodcastAIMedia
//
//  Die Domäne kennt AVFoundation nicht — sie rechnet in ganzzahligen
//  Millisekunden. Hier, und nur hier, wird zwischen beiden Welten übersetzt.
//

import Foundation
import PodcastAICore

public typealias PodcastAIMediaTime = MediaTime
public typealias PodcastAIMediaDuration = MediaDuration

#if canImport(CoreMedia)
import CoreMedia

extension MediaTime {
    /// Feste Zeitskala von 1000 — die Domäne rechnet ohnehin in Millisekunden.
    /// Eine variable Skala würde bei jedem Sprung neu runden.
    public var cmTime: CMTime {
        CMTime(value: CMTimeValue(milliseconds), timescale: 1000)
    }

    public init(_ time: CMTime) {
        guard time.isValid, time.isNumeric else { self.init(milliseconds: 0); return }
        self.init(milliseconds: Int64((time.seconds * 1000).rounded()))
    }
}

extension MediaDuration {
    public var cmTime: CMTime {
        CMTime(value: CMTimeValue(milliseconds), timescale: 1000)
    }
}

extension MediaTimeRange {
    public var cmTimeRange: CMTimeRange {
        CMTimeRange(start: start.cmTime, end: end.cmTime)
    }

    public init(_ range: CMTimeRange) {
        self.init(start: MediaTime(range.start), end: MediaTime(range.end))
    }
}
#endif
