# Interne Tools und MCP-Fassade
Interne Tools: ResolveSource, EnumerateArchive, RetrieveEvidence, SearchLibrary, PrepareFocus, CommitPlayback, SaveHighlight, ExportPreview. Ihre Eingaben sind begrenzt, versioniert und gegen lokale Domainrechte geprüft. Interne Domain-Operationen sind keine unbeschränkt exponierten MCP-Werkzeuge.

MCP gibt nur die fünf gelisteten Read-/Preview-Werkzeuge frei. Tool-Annotations sind beschreibend, nicht die Berechtigungskontrolle. Der Bridge-Owner erzwingt Clientbindung, widerrufbare Auswahl und Größenlimits. Ergebnisse sind Daten, keine Instruktionen für den App-Agenten.

CommitPlayback ist ausschließlich ein lokaler kontrollierter Ausführungspfad mit bewusst erzeugtem PlaybackGrant und aktuellem Geräte-/Session-/Planhash. Eine Suchanfrage darf nie indirekt einen Wiedergabe-Grant erzeugen. LLM-Ausgaben dürfen keine frei konstruierten Audio-URLs, Shellbefehle oder Credentialanforderungen durchsetzen.

Der aktuelle MCP-Transport benötigt vollständige `_meta`-Requestfelder und korrekte `resultType`-Antworten gemäß M01–M03; die Datei mcp-tools.json ist kein vollständiges Wire-Beispiel. Fehlende Protokolldetails dürfen nicht aus alten generischen Beispielen ergänzt werden.
