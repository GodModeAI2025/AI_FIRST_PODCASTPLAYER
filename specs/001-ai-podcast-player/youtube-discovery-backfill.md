# Link → Kanal → Feed → rückwirkendes Wissen

## Produktvertrag
Ein einziges Eingabefeld akzeptiert den gewöhnlichen geteilten YouTube-Link. Die App ermittelt Video, Kanal und Feed selbst. Abo wird angeboten, nie still angelegt. „In BrainSpeak abonnieren“ ist ein lokales App-Abo und ändert nicht die YouTube-Kontoeinstellungen. Keine Anmeldung am YouTube-Konto ist Voraussetzung für öffentliche Kanalmetadaten; der offizielle Metadatendienst braucht eine korrekt provisionierte API-Konfiguration. [Y01, Y04–Y06]

**Hauptflow:** Einfügen/Teilen → Link prüfen → Quelle auflösen → Vorschau → Einzelvideo / Kanalabo / ältere Folgen → historische Auswahl → Ressourcen-/Inhaltsprüfung → Batch bestätigen → Fortschritt und neue Erkenntnisse.

## Linkauflösung
URLComponents validiert HTTPS, Host und Pfad. Unterstützt: `youtube.com/watch?v=…`, `youtu.be/…`, `/shorts/…`, `/live/…`, `/embed/…`, `/channel/UC…`, `/@handle` mit Unterseiten und `/user/…`. Bekannte mobile/www-Hostvarianten werden normalisiert; Hostsuffix-Tricks werden verworfen. URL-Parameter werden nach Semantik behandelt, nicht pauschal gelöscht. `t`/`start` bleiben nur für die ausgewählte Einzelwiedergabe relevant. Der spätere Abo-Feed erhält keinen Zeitparameter.

Video-ID wird über `videos.list(part=snippet,id=…)` zum `snippet.channelId` aufgelöst. Handle über `channels.list(forHandle=…)`, alte Username-Form über `forUsername`; bekannte channelID direkt über `id`. Kanalname/Titel sind keine Identität. Der Feed wird aus verifizierter channelID gemäß Google-Form gebildet und mit XMLParser samt zurückgelieferter channelID geprüft. Öffentliche Metadaten kommen über URLSession + Codable, nicht über ein fremdes App-SDK. [Y01, Y04–Y06]

Legacy-Custom-URLs dürfen nach sicherem HTTP-Redirect auf unterstützte kanonische Form aufgelöst werden; keine HTML-/Caption-Scraping-Pipeline. Nicht auflösbare Form erklärt die Grenze und bietet den kanonischen Teilen-Link an, nicht die manuelle Suche nach RSS. Eingefügte Playlists sind keine eindeutigen Kanäle: „Video“/„Playlist“/„Uploader“ bleiben unterscheidbar; volle Playlist-Abos sind P2 und dürfen nicht als Kanal-RSS getarnt werden.

## Vorschau
Titel/Kanal/Originalquelle, Feedstatus „Automatisch erkannt“ und Inhaltsfähigkeiten zuerst. Bei einem Video drei Aktionen: „Nur diese Folge aufnehmen“, „Kanal abonnieren“, „Frühere Folgen analysieren“. Bei Kanal-URL nur sinnvolle Kanalaktionen. Bereits vorhandenes Abo zeigt „Schon abonniert“ plus Einstellungen und Historie statt Dublette. Nach Abo unabhängig: neue Folgen automatisch analysieren, Hörliste, dauerhafter Download, rückwirkende Analyse.

## Historische Auswahl
„Keine“, „Letzte N Folgen“, „Zeitraum“, „Folgen auswählen“, „Gesamtes verfügbares Archiv“. Bei bestehendem Abo jederzeit unter „Ältere Folgen erschließen“. Reihenfolge neueste zuerst, älteste zuerst oder nach Interessen. Interessenpriorität aus Metadaten bleibt ausdrücklich vorläufig. Bei „alle“ wird der bestätigte Katalogsnapshot abgearbeitet; danach eintreffende Uploads gehören zur separaten Neu-Folgen-Policy.

## Warum Archiv nicht nur RSS ist
Der Feed ist der Aktualisierungskanal, nicht die Zusage einer vollständigen Geschichte. Für YouTube liefert `channels.list(part=contentDetails)` die `relatedPlaylists.uploads`-ID. Danach `playlistItems.list(playlistId=…,maxResults=50,pageToken=…)` bis kein `nextPageToken` übrig ist. 50 ist Seitengröße, kein Gesamtlimit. Eigene gespeicherte Historie wird mitverwendet. Kein `search.list`-Shortcut als vermeintlich unbegrenztes Archiv. [Y04, Y05]

Katalogaufbau selbst kann pausieren. Cursor, ETag, Seite, gefundene stabile videoIDs und Snapshotstand werden transaktional gespeichert. Seitenüberschneidungen und neu hinzugekommene Videos sind zu deduplizieren. Ein ungültiger Cursor führt zu kontrolliertem Neustart der Enumeration mit bestehenden IDs, nicht zu doppelter Inhaltsanalyse. Gelöschte/private/regionale Videos zählen als nicht verfügbar. Angaben zur Archivvollständigkeit gelten für den beobachteten API-Snapshot, nicht für sämtliche je veröffentlichten Inhalte.

Bei RSS: vorhandene Feeditems, bereits gespeicherte Historie und vom Publisher tatsächlich veröffentlichte Archive/Medien nutzen. Ein abgeschnittener RSS-Feed ohne Archivangebot ist sichtbar begrenzt. Keine erfundene universelle RSS-Pagination.

## Discovery ist nicht Content-Zugang
Ein gefundenes Video besitzt noch keine erlaubte Audio-/Transkriptquelle. Für jede Episode separat `metadataOnly`, `authorizedText`, `authorizedAudio`, `unavailable` bestimmen. Separater offizieller Podcastfeed oder expliziter Datei-/Textimport kann Analyse erlauben. Titelgleichheit reicht nicht als Beweis für identische Folge oder synchronisierte Zeitachse. YouTube-Caption-Download ist kein allgemeiner öffentlicher Transkriptzugang. Keine Streamextraktion. [Y02, Y03]

Beispiel einer korrekten Fortschrittsanzeige (synthetisch): „120 gefunden · 75 inhaltlich zugänglich · 20 analysiert · 55 bereit zur Analyse · 45 ohne nutzbare Inhaltsquelle“. Für teilweise verarbeitete Folgen zusätzlich Text-/Zeitabdeckung anzeigen. Der Batch kann katalogseitig fertig und analyseseitig teilweise blockiert sein.

## Scheduling und Wiederaufnahme
Zwei persistente Schritte: `CatalogEnumerationJob` und `BackfillAnalysisJob`. Zuerst Nutzerbudget/Netz-/PCC-Policy. Dann begrenzte Medienjobs, bestehende Artefakte wiederverwenden, keine gewaltige Downloadwelle. Historie niedriger als aktive Frage/Wiedergabe und neue gewählte Folge priorisieren. Eigentlicher KI-Auftrag läuft ausschließlich Apple-nativ; Hintergrundfortsetzung unterliegt den beschriebenen Plattformgrenzen. Stop stoppt neue Jobs; fertige Erkenntnisse bleiben. Cancel löscht keine bereits existierenden Notizen. Retry wählt nur Fehlerfälle oder ausdrücklich geänderte Pipeline-Schritte.

## API-/Betriebsgrenzen
Metadatenkonfiguration, Quota und relevante Google-Policies sind Release-Gates. Keine Entwicklergeheimnisse im Repository. Clientseitige API-Konfiguration ist keine geheim haltbare Servervollmacht; Einschränkungen und Quota-/Abuse-Management müssen für den Vertriebsweg geprüft werden. Ohne verfügbaren Metadatendienst bleiben erkannte IDs bzw. importierbare Einzelquellen nutzbar, volle Autoauflösung kann aber blockiert sein. Dies ist ein Fehlerzustand, kein Anlass für inoffizielle Extraktion. Speicherung und Refreshfristen von API-Daten sind vor Release gegen aktuelle YouTube-Vorgaben zu prüfen. [Y02]

## Abnahme
AC-067–073 und AC-086–090. Zusätzlich: Kanalwechsel über Redirect; Timestamp über 1h; erneuter Linkimport; Headroom bei großem Archiv; Offline mitten in Enumeration; Quota zwischen zwei Seiten; neuer Upload während Snapshot; privates Video; ungültiger Cursor; fehlender Inhaltszugang; BrainSpeak-Abmeldung/Profilwechsel. Keine dieser Aufgaben führt ohne Nutzerfreigabe ein Abo oder neue Tonausgabe aus.
