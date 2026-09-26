//
//  Exports.swift
//  PodcastAIKit
//
//  Sammelziel. Die App-Targets importieren `PodcastAIKit` und bekommen
//  damit die gesamte Domäne — statt zehn Importzeilen in jeder Datei.
//

@_exported import PodcastAICore
@_exported import PodcastAISources
@_exported import PodcastAIMedia
@_exported import PodcastAIIntelligence
@_exported import PodcastAIKnowledge
@_exported import PodcastAIPlayback
@_exported import PodcastAISmartFeeds
@_exported import PodcastAIExport
@_exported import PodcastAIShareInbox

#if canImport(SwiftData)
@_exported import PodcastAIPersistence
#endif

#if canImport(Speech)
@_exported import PodcastAITranscription
#endif
