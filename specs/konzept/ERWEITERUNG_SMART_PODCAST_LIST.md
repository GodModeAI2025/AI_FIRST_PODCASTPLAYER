# Smart Podcast List — deine eigenen Themen-Podcasts
**Konzept-Erweiterung 1.3 · 20. September 2026**  
Sonar / BrainSpeak · iOS, iPadOS, watchOS und macOS 27

## Was jetzt hinzukommt
Die App stellt nicht nur relevante Stellen innerhalb einer Originalfolge bereit. Sie führt persönliche Themen-Feeds mit eigenen Folgen. Jede dieser Folgen besteht aus passenden, noch nicht gehörten Originalausschnitten aus deinem freigegebenen Quellenbestand. Die KI wählt und ordnet; die Menschen aus den Originalfolgen bleiben zu hören. Eine synthetische Sprecherstimme ist dafür nicht vorgesehen.

Das Interessenprofil wird einmal konfiguriert und kann mit deiner Zustimmung dazulernen. Die App fragt dann die vorhandenen Inhalte gegen dieses Profil ab, nicht bei jedem Play erneut dich. Die Beispiele aus dem Gespräch sind **iOS/Mobile**, **Google/KI**, **EnBW** und **Datenschutz**. Sie sind mögliche konfigurierbare Themen, keine fest eingebauten Interessen für alle Nutzer.

## Zwei Ebenen, drei Hörmöglichkeiten
**In einer Originalfolge:** „Ganz hören“, „Nur für mich relevante Stellen“ oder eine einzelne markierte Stelle auswählen. Im Relevanzmodus spielt die App passende Abschnitte derselben Folge nacheinander; übrige Abschnitte gelten dadurch nicht als gehört.

**Über mehrere Originalfolgen:** Unter „Für dich → Meine Podcasts“ stehen deine Smart Podcast Lists wie eigene Sendungen. Beispielsweise „Mein Datenschutz-Podcast“ oder ein gemischter Feed „Mein Themen-Update“ für iOS, Google/KI und EnBW. Ein solcher Feed hat ein Cover, eine Beschreibung und eine Liste seiner persönlichen Ausgaben.

**Alles nachholen oder kuratieren:** „Alles Ungehörte“ sammelt sämtliche passenden, abspielbaren und analysierten Abschnitte im gewählten Umfang. Eine optionale Ausgabe „Mein 20-Minuten-Update“ wählt dagegen bewusst einen kürzeren Ausschnitt. Die App zeigt Restbestand und Analyseabdeckung, statt eine Auswahl als vollständig auszugeben.

## So entsteht eine neue persönliche Folge
Neue oder neu erschlossene Quellen liefern passende Originalstellen. Die App zieht deinen segmentgenauen Hörverlauf ab, vermeidet doppelte Einplanung und bildet aus dem verbleibenden Material eine neue Ausgabe. Sie erhält einen Titel, Shownotes, eine Gesamtlänge, Kapitel und ein eigenes Cover. Erst wenn tatsächlich neue passende, zugängliche Abschnitte vorliegen, erscheint „Neue Folge“; eine neue Formulierung des Titels reicht nicht.

Eine Ausgabe kann auch auf ältere Originalfolgen zurückgreifen, die für dich noch ungehört sind. „Neu für dich“ ist deshalb nicht dasselbe wie „heute veröffentlicht“. Das Originaldatum bleibt sichtbar.

### Beispiel — ausdrücklich fiktiv
> **Mein Themen-Update · Ausgabe 12**  
> **Mobile, KI und Unternehmen: deine nächsten Originalstellen**  
> 18 Minuten · 4 Ausschnitte aus 3 Originalfolgen · Noch nicht gehört
>
> Diese Ausgabe bündelt die bisher ungehörten Abschnitte zu deinen ausgewählten Themen. In den Shownotes steht zu jedem Abschnitt, worum es geht, warum er ausgewählt wurde und aus welcher Originalfolge er stammt.
>
> **Abspielen** · **Kapitel** · **Mit dieser Ausgabe chatten** · **Cover gestalten**

Dieses Beispiel meldet keine tatsächlichen Neuigkeiten über Apple, Google oder EnBW.

## Was beim Abspielen passiert
Einmal auf Play drücken autorisiert die Wiedergabe der Ausgabe. Die Originalausschnitte folgen automatisch aufeinander. Sichtbar bleiben aktuelle Quelle, Originalzeitcode und Position innerhalb deiner persönlichen Folge. Per Tipp öffnest du die Originalfolge oder hörst dort weiter. Keine zusätzlichen Bestätigungen bei jedem Quellenwechsel, solange derselbe geprüfte Hörplan läuft. Neue Funde dürfen eine laufende Folge nicht unbemerkt verlängern oder Ton starten.

Die Shownotes sind textuell von Apple Intelligence erstellt und auf die tatsächlich enthaltenen Stellen begrenzt. Das Audio bleibt Originalaudio. Es gibt standardmäßig keine gesprochenen KI-Überleitungen, keine umformulierten Aussagen und keine künstliche Sprecherimitation.

## Was „noch nicht gehört“ bedeutet
Die App speichert abgespielte Zeitintervalle je konkreter Medienfassung, nicht nur einen Schalter für eine ganze Folge. Überspringen, Download, KI-Analyse oder Lesen der Shownotes zählt nicht als Hören. Das System kann Wiedergabe nachweisen, nicht deine Aufmerksamkeit.

Hörst du einen Abschnitt in einer normalen Folge, gilt er auch für die Themen-Feeds als abgespielt. Hörst du ihn im Datenschutz-Feed, wird er im gemischten Themen-Update nicht erneut als neuer Inhalt verkauft. Noch nicht gehörte Reststellen bleiben verfügbar. Bereits bekannte Inhalte lassen sich separat ausblenden; „bekannt“ wird nicht zu „gehört“ umetikettiert.

Du kannst umstellen zwischen **„Ungehörte Abschnitte, auch aus angefangenen Folgen“** und **„Nur noch nicht gestartete Originalfolgen“**. Fehlender früherer Hörverlauf wird als unbekannt behandelt, nicht als sicher ungehört behauptet. Kurze notwendige Kontextwiederholungen werden gekennzeichnet.

## Cover mit Apple Intelligence — mit einer wichtigen Grenze
**Image Playground ist vorgesehen**, mit vorbereiteten Motiven aus dem tatsächlichen Inhalt der Ausgabe. Auf iPhone, iPad oder Mac öffnet „Cover gestalten“ den nativen Image-Playground-Dialog. Du bestätigst das Bild; die App speichert es als Cover dieser Ausgabe. Es werden nur Apple-Stile angeboten, keine externen Modellanbieter. Die Watch zeigt das synchronisierte Cover. [A27, A29, A30]

**Nicht vorgesehen ist eine angeblich lautlose Image-Playground-Generierung im Hintergrund:** Apple hat die programmgesteuerte `ImageCreator`-Schnittstelle für die Plattformen ab Version 27 eingestellt. Die unterstützte Integration führt über den Systemdialog. [A28, A29]

Damit eine neue Folge trotzdem sofort ein eigenes Cover hat, erstellt die App automatisch ein natives Titel-/Themenlayout aus eigener Typografie, Formen und Themenmotiven. Dieses Cover ist keine generierte Image-Playground-Illustration. Optional wird ein einmal bestätigtes Feedmotiv für weitere Ausgaben wiederverwendet; ein neues individuelles KI-Bild lässt sich pro Ausgabe im Systemdialog gestalten. Nicht verfügbare Bildgenerierung blockiert niemals die Folge.

## In der Spezifikation integriert
Die Erweiterung steht nicht nur hier: `spec.md`, `plan.md`, `data-model.md`, Anforderungen, User Stories, Aufgaben, Abnahmefälle, Sync-/Exportregeln und Plattformbeschreibungen wurden ergänzt. Der Detailentwurf steht in `specs/001-ai-podcast-player/smart-podcast-list.md`; vier neue Datenverträge und synthetische Beispiele liegen daneben bzw. unter `fixtures/smart-feed/`.

**Umsetzungsstatus:** spezifiziert und auf Paket-/Datenregeln geprüft, noch keine gebaute App. Vorhandene Bilder sind erhalten; die neuen Screens sind als textuelle Screen-Spezifikation und Mermaid-Flow ergänzt, nicht als fertig gerenderte native Screens ausgegeben.

## Apple-Quellen
- A27: Apple, Image Playground Framework — https://developer.apple.com/documentation/imageplayground
- A28: Apple, Deprecation of the ImageCreator class, 11. Juni 2026 — https://developer.apple.com/news/?id=dz9wvq0r
- A29: Apple, ImageCreator / init — https://developer.apple.com/documentation/imageplayground/imagecreator/init()
- A30: Apple, WWDC26 Session 375, Create high-quality images using Image Playground — https://developer.apple.com/videos/play/wwdc2026/375/
Alle vier wurden für diese Erweiterung am 20. September 2026 geprüft.
