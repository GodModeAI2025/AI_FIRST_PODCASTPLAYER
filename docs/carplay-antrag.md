# Antrag auf die CarPlay-Berechtigung

Formular: https://developer.apple.com/contact/request/carplay/ (angemeldet als Kontoinhaber). Die Felder, wie sie auszufüllen sind:

- **App Type:** Audio
- **Product (Beschreibung):**
  PodcastAI is a podcast player for iPhone, iPad and Mac (bundle ID com.godmodeai.podcastai.mobile, team SP73Z8JWXM). It plays the user's subscribed podcasts and adds on-device transcripts, key facts and topic updates. The CarPlay version is a pure audio player without any AI features.
- **Features:**
  CarPlay Audio scene: tab bar with Subscriptions, New episodes and Up Next; episode lists per podcast; the standard Now Playing template with play/pause, skip back and forward, playback speed and Up Next. Nothing starts playing without a tap or an explicit play command by the user. Audio only, no video, no text entry, no messaging.
- **App Store URL:** https://github.com/GodModeAI2025/AI_FIRST_PODCASTPLAYER (App Store review of version 1.0 in progress)
- **Screenshots:** optional; die iPhone-Bilder des Players aus `docs/store-screenshots` genügen, CarPlay-Bilder gibt es erst nach der Freigabe.
- Zum Schluss die Richtlinien bestätigen und „Submit“ wählen.

Nach der Zusage: Capability „CarPlay Audio App“ an der App-ID `com.godmodeai.podcastai.mobile` eintragen, Profile neu laden, in `app/project.yml` im Ziel `PodcastAI` `PODCASTAI_VARIANT: CarPlay` setzen und `cd app && xcodegen generate`. Alle Schritte stehen in `docs/plan-player-plattformen.md`.

## Stand

Am 1. Oktober 2026 abgeschickt (Mark Zimmermann, Mobile Box, mobile_box@icloud.com). Apple meldet sich per E-Mail. Danach die Schritte oben.
