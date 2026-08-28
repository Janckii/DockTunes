# DockTunes

Ein Spotify-Panel, das sich neben das Dock legt und ihm folgt – als wäre es
Teil davon.

![DockTunes neben dem Dock](docs/dock-and-panel.png)

Zeigt Cover, Titel und Interpret des laufenden Songs, hat Wiedergabetasten,
eine Zeitleiste mit laufender Zeit, eine Tonanzeige, die auf das echte
Ausgabesignal reagiert, und kann den Song in eine Playlist legen. Auf Wunsch
zeigt es statt Cover und Titel den mitlaufenden Liedtext.

## Voraussetzungen

- macOS 14.2 oder neuer (Liquid Glass ab macOS 26, sonst eine Rückfallebene)
- Spotify-Desktop-App
- Xcode Command Line Tools (`xcode-select --install`) – ein Xcode-Projekt
  braucht es nicht

## Bauen und starten

```bash
git clone <repository> DockTunes
cd DockTunes
bash build.sh
open -a ~/Applications/DockTunes.app
```

`build.sh` übersetzt die Quelldatei, legt das App-Bundle in `~/Applications`
an und signiert es.

## Berechtigungen

Beim ersten Start fragt macOS nach zwei Freigaben:

1. **Bedienungshilfen** – nur damit lässt sich auslesen, wo das Dock gerade
   sitzt. Ohne sie bleibt das Panel unsichtbar. Danach die App einmal neu
   starten.
2. **Spotify steuern** – ohne sie kennt DockTunes weder Titel noch Wiedergabe.

Für die Tonanzeige kommt beim ersten Abspielen eine dritte Rückfrage
(Ton mitlesen). Sie wird nur ausgewertet, nichts aufgezeichnet oder gesendet.
Schaltet man die Tonanzeige ab, entfällt die Frage.

## Bedienung

| Aktion | Wirkung |
|---|---|
| Klick auf Cover oder Text | Spotify in den Vordergrund holen |
| Knöpfe rechts | zurück, abspielen/pausieren, weiter |
| Pluszeichen | Song in die zuletzt gewählte Playlist legen |
| Zeiger auf dem Panel | Zeitleiste mit laufender und gesamter Spielzeit |
| Ziehen auf der Zeitleiste | im Song vor- und zurückspringen |
| Scrollen über dem Panel | Lautstärke in Fünferschritten; die Zeitleiste zeigt sie 1,4 s lang an – auch im Liedtext-Modus, dort pausiert der Text so lange |
| Rechtsklick | Menü mit allen Einstellungen |

## Breite

Die Breite ist **fest** und wird nicht vom Titel bestimmt. Eine mitwandernde
Breite wäre bei jedem Lied eine andere, und das Panel wäre ständig in Bewegung.

Eingestellt wird sie im Rechtsklick-Menü unter **Breite**, in vier Stufen
(normal 250 / 380 / 520 / 640, im Liedtext-Modus 420 / 520 / 640 / 760).
Die Stufen sind nicht rund gewählt, sondern an den Inhalt gekoppelt: jede
bringt etwas Sichtbares mehr. Normal- und Liedtext-Modus haben eigene Stufen.
Zwischenwerte über `panelWidth` und `lyricsWidth`, siehe Einstellungen;
weniger als 200 Punkte nimmt das Panel nicht an.

**Je breiter, desto mehr steht drin:**

| ab | kommt dazu |
|---|---|
| 200 | Cover, Titel, Abspielen/Pause, Weiter |
| 280 | Interpret |
| 300 | Zurück |
| 360 | Playlist-Knopf |
| 240 | Tonanzeige (wenn im Menü eingeschaltet) |
| 520 | Album, und Zeitleiste samt Zeiten dauerhaft statt nur beim Zeigen |
| 700 | im Liedtext-Modus: die nächste Zeile als Vorschau |

Die Reihenfolge folgt dem Nutzen: **weiter** ist wichtiger als zurück, und
beides wichtiger als das Plus – im schmalsten Panel steht deshalb die
Weiter-Taste, nicht der Playlist-Knopf.

Die **Tonanzeige** läuft auch im schmalen Panel. Ob sie überhaupt erscheint,
entscheidet der Schalter im Rechtsklick-Menü; sie weicht nur, wenn dem Titel
sonst weniger als 70 Punkte blieben – der Text wäre dort nur noch ein hastig
laufender Schnipsel. Die Schwelle hängt an der Panelbreite und daran, welche
Knöpfe stehen, **nicht** am Titel: sonst ginge die Anzeige bei jedem Lied an
und aus.

**Passt der Titel nicht, läuft er durch** – endlos, mit 34 Punkten je Sekunde
und 40 Punkten Abstand zwischen den Durchläufen. Nur der Titel; der Interpret
wird weiterhin gekürzt, und im Liedtext-Modus bricht die Zeile um statt zu
wandern. Der Lauftext kostet rund 1,5 % eines Kerns, solange er läuft: die
Bewegung lässt die Glasfläche bei jedem Bild neu mischen.

Normal- und Liedtext-Modus merken sich ihre Breite getrennt – der Liedtext
braucht mehr Platz als Cover, Titel und Knöpfe.

## Liedtext

Im Rechtsklick-Menü einschaltbar. Statt Cover und Titel zeigt das Panel dann
die laufende Textzeile und darunter die nächste.

Es steht immer nur die **laufende** Zeile da, dafür über zwei Zeilen, wenn sie
nicht auf eine passt. Die abgeschwächte Vorschau auf die nächste Zeile ist
entfallen: lange Zeilen wurden dadurch abgeschnitten, und das Kommende ist
weniger wert als das Laufende vollständig. Reichen zwei Zeilen nicht, wird
sichtbar gekürzt statt stillschweigend abgeschnitten.

Beim Zeilenwechsel steigt die neue Zeile ein und blendet auf (260 ms) – sonst
steht der Text plötzlich anders da und der Wechsel geht unter.

Vor der ersten Zeile und in Instrumentalpausen stehen Titel und Interpret
statt einer leeren Fläche.

Ab 700 Punkten Breite steht die nächste Zeile wieder darunter – dort nimmt sie
der laufenden nichts weg. Die Breite lässt sich ziehen oder im Rechtsklick-Menü
in vier Stufen wählen.

Die Texte kommen von [lrclib.net](https://lrclib.net), einem offenen
Verzeichnis ohne Anmeldung. Dorthin gehen Titel und Interpret des laufenden
Songs – sonst nichts.

Die Zeitmarken sind **zeilenweise**, nicht wortweise – ein Karaoke-Modus mit
mitwanderndem Wort ließe sich daraus nur schätzen. Siehe „Was nicht geht".

Eine Fassung wird nur übernommen, wenn Laufzeit (auf 4 Sekunden genau) **und**
Interpret passen. Beides als Bedingung, nicht nur als Reihung – sonst landet
ein gleichnamiges Stück eines anderen Künstlers im Panel. Passt keine Fassung,
bleibt es bei Titel und Interpret.

## Playlists

Der Knopf mit dem Pluszeichen legt den laufenden Titel in die zuletzt gewählte
Playlist. Die Auswahl ist ein eigenes Fenster mit Suchfeld; Playlists lassen
sich über den Stern zu Favoriten machen, die dann oben stehen.

Das geht nicht über AppleScript – Spotify kennt dafür keinen Befehl – sondern
über Spotifys Web-Schnittstelle. Sie verlangt eine einmalige Einrichtung:

1. Auf [developer.spotify.com](https://developer.spotify.com/dashboard) eine
   App anlegen (kostenlos)
2. Als Redirect URI genau `http://127.0.0.1:8888/callback` eintragen
3. Client-ID kopieren und beim ersten Klick auf das Pluszeichen einsetzen

Angemeldet wird per PKCE, es liegt also kein Geheimnis in der App. Die
Zugangsdaten landen in `~/Library/Application Support/DockTunes/credentials.json`
mit Rechten 0600.

## Einstellungen

Alles über das Rechtsklick-Menü. Zusätzlich per `defaults`:

```bash
defaults write de.jancko.docktunes volumeStep -int 2      # Lautstärke je Raste (Vorgabe 5)
defaults write de.jancko.docktunes followRate -int 30     # Abfragen je Sekunde
defaults write de.jancko.docktunes rimAlpha -float 0.30   # Stärke der Lichtkante
defaults write de.jancko.docktunes panelWidth -float 460  # Breite, normal (ab 200)
defaults write de.jancko.docktunes lyricsWidth -float 580 # Breite im Liedtext-Modus
```

---

# Technische Notizen

Die folgenden Abschnitte dokumentieren Entscheidungen, die beim Nachbauen sonst
wie Willkür wirken. Alle Zahlen sind nachgemessen, nicht geschätzt.

## Verhalten

Das Panel folgt der Position des Docks:

- Abgefragt wird 60-mal je Sekunde, solange der Zeiger beim Dock ist – nur dann
  ändert sich dessen Größe (Vergrößerung, Ein- und Ausfahren). Sonst fünfmal.
  Nachgemessen: die Lücke zwischen Dock und Panel bleibt während der
  Vergrößerung konstant. Einstellbar mit
  `defaults write de.jancko.docktunes followRate -int 30`.
- Es sitzt immer rechts neben dem Dock, exakt in dessen Höhe. Das sichtbare
  Dock-Glas liegt 5 Punkte tiefer als die Symbolliste, die die Bedienungshilfen
  melden – dieser Versatz ist eingerechnet und bei Dock-Größe 35, 50 und 70
  nachgemessen. Passt das Panel rechts nicht hin, weicht es nach links aus.
- Bewegungen laufen weich aus (rund 80 ms), größere Sprünge werden sofort
  gesetzt, damit ein Bildschirmwechsel nicht über den Schreibtisch fliegt.
- Die Füllung ist gegen den Dock ausgemessen, nicht geschätzt. Der Dock mischt
  streng linear – Helligkeit = 0,660 · Grund + 58 im Hell-, 0,720 · Grund + 17
  im Dunkelmodus, über Prüfflächen von Schwarz bis Weiß ohne Abweichung.
  Liquid Glass tut das nicht: es hellt sich über halbheller Fläche selbsttätig
  auf und kippt über sehr heller ins Dunkle. Wie das Panel den Dock trotzdem
  trifft, steht im Quelltext bei `applyFill`. Größte verbleibende Abweichung:
  4 von 255 Stufen im Hell-, 6 im Dunkelmodus.
- Die helle Kante läuft oben **und** unten, je einen Punkt, an den Seiten nur
  angedeutet – so wie beim Dock (gemessen 140 gegen 88 Fläche). Trifft auf
  0,5 Stufen. Feinjustage: `defaults write de.jancko.docktunes rimAlpha -float 0.30`.
- Kein Schlagschatten. Der Dock wirft keinen: der Grund neben ihm misst exakt
  den Wert des Hintergrunds. Mit Schatten saß das Panel sichtbar *auf* dem
  Bild statt darin.
- Die Textfarbe hängt bewusst **nicht** am Systemmodus: Wie hell die Panelfläche
  ist, bestimmt der Hintergrund dahinter (gemessen 0,21 über Schwarz bis 0,88
  über Weiß), nicht Hell- oder Dunkelmodus. Heller Text mit Schatten trägt auf
  beidem. Über einem sehr hellen Fenster direkt hinter dem Dock bleibt er
  grenzwertig – ein Kompromiss zugunsten der Dock-Optik.
- Es wächst und wandert mit, wenn sich die Dock-Breite ändert.
- Verschwindet das Dock (Vollbild, automatisches Ausblenden), verschwindet das
  Panel mit.
- Es ist auf allen Schreibtischen sichtbar und liegt auf derselben
  Fensterebene wie das Dock.
- Ohne laufendes Spotify oder ohne geladenen Titel bleibt es unsichtbar.

Klicks auf das Panel holen die App nicht in den Vordergrund – das Fenster, in
dem gerade gearbeitet wird, behält den Fokus.

## Rechenzeit

Gemessen mit `top -l 5` auf einem Kern. (`ps -o %cpu` taugt hier nicht – das
ist der Durchschnitt über die ganze Laufzeit, nicht der aktuelle Wert.)

| Zustand | vorher | jetzt |
|---|---|---|
| pausiert, Zeiger woanders | 4,0 % | **1,2 %** |
| spielt, Zeiger woanders | 7,6 % | **2,8 %** |
| spielt, Zeiger auf dem Panel | 9,3 % | **4,6 %** |
| Liedtext-Modus, spielt | 3,2 % | **2,8 %** |

Woher die Ersparnis kommt:

- **Zeichnen im Glas ist teuer.** Jedes `draw(_:)` in einer
  `NSGlassEffectView` lässt die ganze Fläche neu mischen – gemessen 1,7 ms je
  Durchlauf. Die Tonanzeige tat das 30-mal je Sekunde, die Zeitleiste 10-mal.
  Beide bestehen jetzt aus `CALayer`n: nur noch Höhe und Deckkraft setzen,
  den Rest macht der Compositor. Das allein waren knapp 5 Prozentpunkte.
- **Die Dock-Abfrage läuft nur, wenn sie etwas erfahren kann.** Der Dock
  ändert seine Größe nur, wenn der Zeiger bei ihm ist (Vergrößerung) oder er
  ein- und ausfährt. Sonst genügen fünf Blicke je Sekunde statt sechzig. Die
  Zeigerposition abzufragen kostet nichts, die Bedienungshilfen 0,06 ms – bei
  60 Hz sind das 2 % Dauerlast.
- **Unsichtbares wird nicht gerechnet.** Zeitleiste und Zeiten erscheinen erst
  beim Hovern; ohne Zeiger auf dem Panel läuft der Takt gar nicht. Die Leiste
  wird nur neu gesetzt, wenn sie sich um mindestens einen Punkt bewegt – bei
  drei Minuten Spielzeit ist das etwa alle anderthalb Sekunden statt zehnmal
  je Sekunde.
- **Text nur bei echter Änderung.** Im Liedtext-Modus lief `setTexts` zehnmal
  je Sekunde und baute jedes Mal zwei Attributtexte samt Schatten neu auf,
  obwohl die Zeile alle paar Sekunden wechselt.
- **Der Abfragetakt richtet sich nach dem Zustand.** Ein Abruf über AppleScript
  kostet 55 ms. Während der Wiedergabe alle 5 Sekunden, bei Pause alle 20 –
  da bewegt sich nichts, und einen echten Wechsel meldet Spotify von selbst.
- **Feste Puffer in der Tonanalyse** statt vier neuer Anlagen je Durchlauf, und
  der Ringspeicher wird blockweise kopiert statt Wert für Wert mit Modulo.

Frühere Runde: der Dock-Prozess wird nur alle zwei Sekunden gesucht (die
Prozessliste zu durchsuchen kostete 0,2 ms je Takt), und hat sich die
Dock-Geometrie nicht geändert, bricht der Durchlauf sofort ab. Das brachte
21 % auf 4 %.

## Maßraster

Alle Abstände im Panel folgen zwei Werten: 8 Punkte nach außen, 10 Punkte
zwischen den Elementen (Knöpfe untereinander 4).

Die Panelbreite richtet sich nach dem Inhalt. Bei fester Breite entstand
zwischen Titel und Tonanzeige eine Lücke, die je nach Titellänge anders ausfiel –
die Abstände waren damit nicht gesetzt, sondern zufällig.

Die Zeitleiste zeigt links die laufende, rechts die gesamte Spielzeit – beide
mit fester Breite, damit die Leiste beim Ticken nicht wandert.

## Abstände im Panel, nachgemessen

| Strecke | Wert |
|---|---|
| Cover → Titel | 12 px |
| Titel → Tonanzeige | 11–12 px |
| Tonanzeige → erster Knopf | 12 px |
| Knopf → Knopf | 12 px |

Die Knöpfe sitzen **nicht** in gleich breiten Rahmen. Ihre Symbole sind
unterschiedlich breit (24, 13, 24 und 18 px) und tragen zudem ungleiche Ränder –
der Zurück-Pfeil etwa 0 px links und 2 px rechts. Gleiche Rahmen ergeben damit
sichtbar ungleiche Abstände (gemessen 13, 12 und 8 px). Die App misst deshalb
beim Start die tatsächlich bemalte Fläche jedes Symbols und richtet die Rahmen
daran aus; die verbleibenden ein bis zwei Punkte sind als Festwerte im Code
ausgeglichen und dort begründet.

Gemessen wird mit zwei Schwellen: Bei voller Deckung liegen alle
Knopfabstände auf 12 px, zählt man die weichen Antialiasing-Ränder mit, streuen
sie um einen Punkt. Enger geht es auf einem Punktraster nicht.

## Zeitleiste, nachgemessen

| Strecke | Wert |
|---|---|
| laufende Zeit → Leiste | 8 px |
| Leiste → Gesamtzeit | 8 px |
| Gesamtzeit → Panelrand | 11 px |

Die Zeitfelder bekommen beide die Breite des breiteren Textes; feste Felder
ließen dort Luft, wo der Text schmaler war, und rückten die Leiste sichtbar aus
der Mitte. Die linke Zeit ist rechtsbündig, damit sie an der Leiste anliegt.

Ziffern tragen unterschiedlich viel Tinte an ihren Rändern – gleiche gesetzte
Abstände wirken deshalb um einen Punkt ungleich. Der rechte Abstand ist um
diesen Punkt korrigiert; nachgeprüft bei 0:15, 0:49, 1:15 und 1:43, überall
8 zu 8 Pixel.

Der Strich sitzt mittig in seinem Feld, damit er auf einer Linie mit den Zeiten
liegt statt darüber zu schweben.

## Liedtext-Modus, nachgemessen

Dieselben Werte wie im normalen Modus:

| Strecke | Wert |
|---|---|
| laufende Zeit → Leiste | 8 px |
| Leiste → Gesamtzeit | 8 px |
| Panelrand → laufende Zeit | 11 px |
| Gesamtzeit → Panelrand | 11 px |
| Tonanzeige → erster Knopf | 12 px |
| Knopf → Knopf | 12 px |

Play und Pause sind unterschiedlich geformt und brauchen je einen eigenen
Feinversatz – mit einem gemeinsamen Wert lag der Abstand beim Pause-Zeichen um
einen Punkt daneben.

## Signatur

`build.sh` signiert ad-hoc, wenn kein eigenes Zertifikat da ist. Das genügt zum
Ausprobieren, hat aber einen Haken: Eine Ad-hoc-Signatur bekommt bei jedem Bauen
eine neue Kennung, und macOS verlangt danach jedes Mal die Freigaben von vorn.

Wer öfter baut, legt sich einmalig ein eigenes selbstsigniertes Zertifikat mit
dem Namen `Jancko DockTunes Signing` im Schlüsselbund an (Schlüsselbundverwaltung
→ Zertifikatsassistent → Zertifikat erstellen, Art „Codesignatur"). `build.sh`
findet es dann von selbst, die Kennung bleibt stabil und die Freigaben halten.

Ein Zertifikat liegt aus naheliegenden Gründen nicht im Repository.

## Fehlersuche

Die App schreibt ihren Zustand nach `/tmp/docktunes-status.txt` – dort steht
sofort, ob eine Freigabe fehlt, Spotify stumm bleibt oder das Dock nicht
gefunden wird.

## Was nicht geht

**Karaoke mit mitwanderndem Wort.** Dafür bräuchte es Zeitmarken je Wort.
lrclib liefert nur je Zeile – über mehrere Titel geprüft, keine einzige
Wortmarke. Wortgenaue Daten haben Musixmatch, Apple Music und Spotify selbst,
alle drei nur über bezahlte oder nicht öffentliche Schnittstellen.

Schätzen ließe es sich (Zeilendauer auf die Wörter verteilen, nach Länge
gewichtet), aber gesungen wird nicht gleichmäßig: bei gehaltenen Tönen und
Pausen mitten in der Zeile läuft die Markierung sichtbar falsch. Das sähe nach
Karaoke aus, ohne es zu sein.

Was ehrlich ginge: ein Balken, der in der Zeilendauer einmal von links nach
rechts durch die Zeile läuft. Der stimmt an beiden Enden genau und behauptet
dazwischen nichts über einzelne Wörter.

**Die Breite mit der Maus ziehen, wie bei einem Fenster.** Probiert und wieder
ausgebaut. Das Ziehen selbst ließ sich hinbekommen (ein echter, unsichtbar
gemachter Fensterrahmen: `.titled` mit `.resizable`, dazu `canBecomeKey` und
ein überschriebenes `constrainFrameRect` – macOS schiebt Fenster mit Rahmen
sonst um 50 Punkte aus dem Dock-Bereich). Nur der Mauszeiger wechselte an der
Kante nie auf das Größensymbol, und ohne das fehlt der Hinweis, dass man dort
ziehen kann.

Acht Anläufe für den Zeiger, alle wirkungslos: `NSCursor.set()`, `push()`,
zehnmal je Sekunde nachgesetzt, für die ganze Panelfläche, per
`.cursorUpdate`-Zone, per `.mouseMoved`-Zone, auf `.floating` statt Dock-Ebene,
und mit aktivierter App. Den Zeiger vergibt die aktive Anwendung, und DockTunes
aktiviert sich nie – Klicks aufs Panel sollen den Fokus nicht stehlen.
`mouseEntered` erreicht ein Fenster ohne Fokus noch, `mouseMoved` und
`cursorUpdate` nicht mehr.

Die vier Stufen im Menü tun dasselbe mit weniger Umstand.

## Lauftext, warum als Bild

Der durchlaufende Titel ist **ein** Bild mit zwei Abzügen des Textes, das eine
`CALayer` schiebt. Zwei Textfelder nebeneinander wären naheliegender und waren
der erste Versuch – AppKit zeichnet eine Ansicht aber nicht, solange sie
außerhalb des Ausschnitts liegt. Die zweite Kopie blieb dadurch leer, und
zwischen den Durchläufen klaffte eine Lücke von mehreren Sekunden
(nachgemessen: 7 von 10,6 Sekunden Umlauf). `wantsLayer` auf den Textfeldern
half nicht.

## Mitmachen

Alles steckt in einer Datei, `DockTunes.swift`. Kein Xcode-Projekt, kein
Paketmanager – `bash build.sh` genügt. Quelltext und Kommentare sind auf
Deutsch.

Zwei Dinge, die beim Weiterbauen wichtig sind:

- **Gemessen statt geschätzt.** Fast jede Zahl im Quelltext (Abstände,
  Helligkeiten, Kantenstärken) steht dort, weil sie nachgemessen wurde, und der
  Kommentar daneben sagt, woran. Wer sie ändert, sollte neu messen – ein
  Bildschirmfoto und ein paar Zeilen Pixelvergleich reichen.
- **Ein privater Systemschlüssel.** Um die Füllung des Docks zu treffen, setzt
  `PlayerView.tune` die Glasvariante über `_variant`. Die öffentlichen Stufen
  von `NSGlassEffectView` mischen nicht linear und passen deshalb nur für genau
  einen Hintergrund. Der Aufruf ist mit `responds(to:)` abgesichert: fällt der
  Schlüssel in einer künftigen macOS-Fassung weg, läuft die App weiter, die
  Farbe sitzt dann nur nicht mehr genau.

## Lizenz

Siehe [LICENSE](LICENSE).
