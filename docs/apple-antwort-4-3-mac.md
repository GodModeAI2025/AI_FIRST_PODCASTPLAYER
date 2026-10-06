# Antwort an Apple zur Ablehnung 4.3 / 4.2.6 (PodcastAI Mac 1.0)

Stand 6. Oktober 2026. Einreichung 36eb5623-37e2-46f1-9f35-ccfd30489095, Build 1.0 (202610010828). Die Antwort steht auf Englisch, weil sie ins Resolution Center geht. Sie beantwortet Apples neun Fragen in der Reihenfolge der Nachricht.

---

Hello,

thank you for the detailed questions. PodcastAI Mac is an original product that we designed and wrote ourselves, and we believe it meets guidelines 4.3(a), 4.3(b) and 4.2.6. We are not resubmitting the binary. Below are answers to all nine questions. We kept marketing language out of them.

**1. What the app does and the problem it solves**

PodcastAI is a podcast player whose central object is the spoken word itself, not the episode list. A podcast app normally leaves a listener with two choices for a 60-minute episode: listen to all of it, or skip around blindly. PodcastAI removes that choice.

For every episode, the app creates a time-coded transcript on the device with Apple's SpeechAnalyzer. Every word carries its position in the original audio. From the transcript it then derives, with Apple Intelligence (Private Cloud Compute first, the on-device model as fallback):

- the key statements of the episode ("facts"), each pinned to a timestamp and to the exact wording in the transcript,
- tags for every chapter, which the user can follow or mute,
- answers to questions that the user types, either about one episode or across all episodes the user owns. Every answer lists its evidence as podcast, episode and timestamp, and a tap plays the original passage.

On top of this, "Topic Updates" builds a personal podcast from the tags a user follows: each edition collects the chapters from several subscribed podcasts that the user has not heard yet, with an overview as chapter 0. Moments can be saved with a note, and everything can be exported as Markdown (for example to Obsidian). On the Mac, other programs such as AI agents can read the knowledge base over MCP, but only after the user explicitly allows it in Settings, on that Mac only and without a network port.

The primary problem: finding, verifying and reusing what was said in long audio, without trusting a summary. The app never summarizes without pointing to the original moment. Nothing plays unless the user taps it.

**2. Intended user**

- People who regularly listen to information-dense spoken-word podcasts (news, politics, technology, science, business, in German and English) and who need to find or check a statement later. Examples: someone who remembers "somebody said something about data protection and the USA last week" and wants the passage, not the episode.
- Knowledge workers, researchers, journalists and students who keep notes in tools such as Obsidian or Notion and want quotations with a source and a timestamp.
- Listeners with many subscriptions who cannot hear everything and want one personal episode per topic instead of scanning feeds.
- Users of devices with Apple Intelligence. The app requires macOS 27 and a Mac with Apple Intelligence. Beginners can use it as a normal player (search, subscribe, listen, chapters, sleep timer, resume across devices) and ignore the rest.

**3. Need or gap that existing apps do not address**

Established players such as Apple Podcasts, Overcast and Pocket Casts are very good at playback, queues and sync. Some now show transcripts. What we did not find in any of them together:

- a transcript that is created on the device for any feed, not only for publishers that supply one, and in which every statement is bound to a second in the original audio,
- questions answered across the user's whole library with evidence per answer (podcast, episode, timestamp), including follow-up questions and scoping by podcast, tag, episode or time range such as "last week",
- tag-based chapters that the user controls with plus and minus, and a personal podcast made of unheard chapters from several shows (Topic Updates),
- an export path (Markdown) and, on the Mac, a controlled read-only agent interface (MCP),
- privacy by construction: transcription and search on the device, language-model work only on Apple's Private Cloud Compute, no account with us, no analytics, no ads, no third-party AI provider.

The app is a Mac app in its own right, not a scaled-up iPhone app: a sidebar for subscriptions, tags, saved moments and topic updates, the player in the toolbar, keyboard control and the MCP interface.

**4. Beta testing**

We tested through TestFlight from 0.1 (22 September 2026) to 1.0 (28 September 2026) on iPhone, iPad and Mac, and applied feedback in each build. The release notes of every build list what came from testers. Examples that went into the production build:

- Feeds from Transistor (for example `feeds.transistor.fm/ai-to-the-dna`) could not be subscribed because the app took them for web pages. Fixed in the feed detection.
- Direct MP3 links (for example from Podigee) failed at a size limit. They now become single episodes.
- Several episodes started at once caused the "Maximum number of recognizers" error. Episodes are now processed one after another.
- Background work on the iPhone stopped after a short time because iOS ended it when the progress display did not move. The progress now counts the whole run (download by bytes, transcript, facts per section, tags), and the app registers the background task earlier.
- The chat was slow under load. All Apple Intelligence requests now go through one queue, user actions first. Time to first word dropped from 6.7 s to 3.6 s in our measurement.
- Testers asked for whole episodes instead of snippets, for chapters, a queue, and clearer error messages. Each of these is in the production build.
- A running Topic Update edition showed "Play" instead of "Pause". Fixed.

The test suite grew with it and now has more than 1,000 automated tests.

**5. Standalone product or part of a suite**

PodcastAI is part of a small portfolio of apps from MOBILE BOX, each with a different purpose. It is the only podcast player on our account. The other apps deal with different tasks: for example AgendusPro (tasks, projects, kanban boards, calendar and time tracking), MeetingBrain (transcribing and reviewing meetings), Argus Brain (screenshots and PDF), BrainSpeak, Sealed Time Capsule and LocalMCP. None of them plays, subscribes to or manages podcasts, and none has a feed reader, an episode library or a player. PodcastAI does not duplicate what any of them does.

PodcastAI also ships as separate, differently scoped binaries within the same product line, each with its own bundle identifier: the iPhone and iPad app (with an Apple Watch player), this native Mac app, and an Apple TV player. The Mac app is a native macOS app, not a Catalyst build of the iPhone app.

**6. Could this be an in-app purchase or feature of another app on the account?**

No. A podcast library needs feed ingestion (RSS, Atom, OPML, Podcast Index and Apple Podcasts search), a playback engine with chapters, queue and background audio, an episode store that syncs through CloudKit, a transcription pipeline and a retrieval layer over all transcripts. None of our other apps has these parts, and adding them would turn those apps into something else. Their privacy profiles also differ. For example, a meeting transcriber handles recordings of conversations, while PodcastAI never records anything and only handles public podcast audio that the user chose to subscribe to. Keeping the apps separate keeps each privacy notice accurate and short.

**7. Shared code, frameworks or assets with other apps on the account**

No significant shared code, frameworks or assets. PodcastAI is built on its own Swift package, `PodcastAIKit` (14 modules, about 87,000 lines of Swift in the apps and the package, plus about 23,000 lines of tests), written only for this product. It contains the feed parsing, the playback engine, the transcription pipeline, the retrieval and Topic Update logic, the CloudKit schema and the export. The binary uses only Apple system frameworks (SwiftUI, SwiftData, CloudKit, AVFoundation, Speech, FoundationModels, Private Cloud Compute). It contains no third-party SDKs and no shared framework with another app on our account.

**8. Shared codebase, SDK or content library with a third-party app**

No. There is no third-party package, template, app generator or content library in the project. All code and all content in the app are ours. Podcasts are fetched live from the public feeds of the shows the user subscribes to. The app adds the original functionality described above on top of those feeds: on-device transcription with timestamps, facts and tags with evidence, cross-library questions, Topic Updates and export.

**9. Created for a client or third party**

No. PodcastAI was created by MOBILE BOX – App Consulting UG (haftungsbeschränkt) for its own account. The concept, the code, the name and the artwork are ours. We did not use a commercial template or an app generation service, so guideline 4.2.6 does not apply. The Support and Privacy pages are our own: https://github.com/GodModeAI2025/AI_FIRST_PODCASTPLAYER#support and https://github.com/GodModeAI2025/AI_FIRST_PODCASTPLAYER/blob/main/docs/datenschutz.md. The source repository is public at https://github.com/GodModeAI2025/AI_FIRST_PODCASTPLAYER, so the reviewer can verify the points above.

**How to try it**

No account is needed. Subscribe to any podcast through the search field (for example "Think Different. Think AI."), open an episode, and wait for the transcript. The tabs "Facts" and "Questions" then work on that episode, and "Topic Updates" builds the personal podcast. The app needs macOS 27 and a Mac with Apple Intelligence. Audio only plays after a click.

We are happy to answer further questions or to provide a TestFlight invitation for the reviewer.

Best regards,
Mark Zimmermann
MOBILE BOX – App Consulting UG (haftungsbeschränkt)
