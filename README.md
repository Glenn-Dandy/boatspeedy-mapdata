# BoatSpeedy Kartendaten

Wasserwege aus OpenStreetMap, in Kacheln geschnitten, aus denen die App ihre Routen
selbst rechnet. Ein nginx im Docker-Container liefert sie aus; erzeugt werden sie von einem
zweiten Container, der nur läuft, wenn man ihn ruft.

Die App selbst liegt in [Glenn-Dandy/BoatSpeedy](https://github.com/Glenn-Dandy/BoatSpeedy).

## Warum das nötig war

Zum Rechnen einer Route muss die App wissen, wo die Wasserwege verlaufen. Bisher fragte
sie das bei jeder Route über die **Overpass-Schnittstelle** an: öffentliche Server, von
aller Welt genutzt und entsprechend oft überlastet. Gemessen am 4. September 2026:

| Server | von fünf gleichen Anfragen |
|---|---|
| `overpass-api.de` | keine Verbindung |
| `overpass.kumi.systems` | zweimal beantwortet, dreimal 504 nach je 40 s |
| `overpass.private.coffee` | zweimal beantwortet, zweimal 504, einmal gar nichts |

Routing scheiterte damit häufiger, als es gelang. Mit den Kacheln wird **einmal**
geladen, danach rechnet das Handy die Route selbst, ohne auf diese Server angewiesen zu
sein. Die Karte darunter kommt weiterhin von OpenStreetMap und braucht Netz.

## Aufbau

```
regions.txt            welche Gebiete eingelesen werden
build/build.sh         holen -> filtern -> ausgeben
build/tile.py          in Kacheln schneiden
nginx/default.conf     Auslieferung
data/                  Ergebnis (nicht im Repo)
```

### Die Kacheln

Ein Grad breit und hoch, am Boden etwa 110 × 70 km. Benannt nach der Südwestecke:
`n50e011.json.gz`. Ein Umkreis von 150 km sind rund zehn Kacheln.

Der Inhalt entspricht dem, was die App von Overpass bekäme: `elements` mit `type`,
`tags` und `geometry`. So liest sie beide Quellen mit demselben Code, nur die Herkunft
wechselt. Enthalten sind:

- Flüsse, Kanäle und Fahrwasser, ohne Bäche (sie waren 87 % der Daten und kaum befahrbar)
- Schleusen: die Kammern (`lock=yes`, auch nur als `seamark:type=lock_basin`) mit Name,
  Zeiten, Telefon, Funkkanal und Maßen, dazu die Tore
- Wehre, Dämme und Sperrzeichen, als Knoten und als Weg quer über den Fluss
- Umtragewege (`whitewater=portage_way`, `canoe=portage`, `portage=*`) und Ein- und
  Ausstiege am Ufer (`leisure=slipway`, `canoe=put_in`, `whitewater=*`)
- Wasserkraftanlagen (`generator:source=hydro`, `plant:source=hydro`)
- alle Seezeichen samt ihrer `seamark:`-Merkmale, darunter Brücken mit Durchfahrtshöhe und
  Hinweisschilder mit Geschwindigkeitsangaben

Wege, die über eine Kachelkante laufen, liegen **vollständig in beiden** Kacheln. Das
kostet etwas Doppelung, dafür passt das Netz beim Zusammensetzen lückenlos zusammen.
Grenzflüsse, die in zwei Länderauszügen vorkommen, werden über ihre OSM-Kennung
entdoppelt.

Dazu ein `index.json` mit allen Kacheln, ihrer Größe und dem Stand jeder einzelnen, auf die
Minute. Daran sieht die App, was es gibt, was ein Download kostet und welche geladenen
Kacheln veraltet sind. Eine Kachel behält ihren Stand, solange sich ihr Inhalt nicht ändert.

## Betrieb

```bash
git clone git@github.com:Glenn-Dandy/boatspeedy-mapdata.git
cd boatspeedy-mapdata
cp .env.example .env
docker compose run --rm mapdata-build     # dauert, je nach Gebiet
docker compose up -d mapdata-web
```

Danach horcht der Auslieferer auf Port 8081:

```bash
curl http://127.0.0.1:8081/healthz        # ok
curl http://127.0.0.1:8081/index.json     # Verzeichnis der Kacheln
```

Von außen erreichbar wird er über den Reverse-Proxy, als Unterpfad `/mapdata/` der
Projektseite.

### Verwalten

`./manage.sh` ist ein Menü auf dem Server:

- **Auffrischen:** holt für jedes Gebiet nur die Änderungen seit dem letzten Mal und baut
  alle Kacheln neu. Der übliche Fall, gut eine Stunde.
- **Gebiete auffrischen:** dasselbe für ausgewählte Länder, mit ihrem Stand daneben.
- **Neu aufbauen:** verarbeitet alles von vorn, ohne Download. Nötig, wenn sich Filter
  oder Kachelformat geändert haben.
- **Letzter Lauf / Aktueller Lauf:** was dabei herauskam oder gerade passiert, Schritt für
  Schritt; dazu Zusehen, Abbrechen, Gebietsübersicht, Auslieferer prüfen, Platz freigeben.

Bewusst als Shell-Skript und nicht als Adminbereich im Browser: Ein Knopf im Netz
bräuchte Anmeldung, einen eigenen Dienst und einen Weg, einen Lauf zu starten,
üblicherweise über den Docker-Socket, was faktisch Root auf der Maschine bedeutet. Für
etwas, das ein paar Mal im Jahr gebraucht wird, ist das ein schlechtes Geschäft.

Das Menü weigert sich, einen zweiten Lauf zu starten, solange einer aktiv ist: Zwei
schreiben in dasselbe Arbeitsverzeichnis und zerlegen sich gegenseitig die Daten. Läufe
werden mit `setsid` gestartet und laufen weiter, wenn die Sitzung endet.

### Auffrischen

Im Menü über **Auffrischen**. Ohne Menü, etwa aus einem Cron-Eintrag, erzeugt
`./update.sh` alles neu und startet den Auslieferer durch; wie oft, ist keine Kostenfrage
mehr (siehe unten).

### Aktualisiert wird, nicht neu geladen

Ein einmal geholter Auszug wird **behalten** und bei jedem weiteren Lauf über
Geofabriks Änderungsstrom auf Stand gebracht, statt neu geladen zu werden. Die Auszüge
tragen im Kopf, wo ihr Strom liegt und auf welchem Stand sie sind
(`osmosis_replication_base_url`, `osmosis_replication_sequence_number`);
`pyosmium-up-to-date` holt daraufhin nur die Tagesdifferenzen.

| | Tagesdifferenz | Vollauszug |
|---|---|---|
| Luxemburg | 21 bis 236 kB | 47 MB |
| Deutschland | 6,2 MB | 4,8 GB |

Bei monatlichem Auffrischen ist das für Deutschland der Faktor siebenundzwanzig. Ganz
Europa liegt damit als rund 28 GB auf der Platte; dafür lädt ein Lauf danach fast
nichts mehr, und die Daten dürfen ruhig öfter frisch geholt werden.

Das ist keine Bequemlichkeit, sondern Rücksicht: Beim Suchen zweier Fehler kamen an
einem Tag vier volle Deutschland-Downloads zusammen, rund 20 GB. Danach wies Geofabriks
Proxy jeden weiteren mit einem sofortigen 502 ab, und ein ganzer Europa-Lauf scheiterte
an allen Gebieten.

Scheitert die Aktualisierung, wird der vorhandene Auszug weiterbenutzt. Er ist dann nur
älter, nicht kaputt. Erst wenn er die Altersgrenze von `MAX_AGE_DAYS` (180) reißt, wird
doch neu geladen. `KEEP_PBF=0` löscht die Auszüge wie früher sofort nach dem Filtern.

### Wiederaufnahme

Ein abgebrochener Lauf wird beim nächsten Aufruf dort fortgesetzt, wo er stand: Länder
mit vorhandenem Zwischenergebnis werden übersprungen. `FRESH=1` fängt von vorn an.

### Platzbedarf

Die Gebiete werden **nacheinander** verarbeitet. Die Rohauszüge bleiben liegen, damit der
nächste Lauf nur die Änderungen holt: Für ganz Europa sind das rund 28 GB, dazu die
Zwischenergebnisse. Mit `KEEP_PBF=0` wird jeder Auszug sofort nach dem Filtern gelöscht;
dann liegt die Spitze bei der Größe des größten einzelnen Auszugs, Deutschland oder
Frankreich je rund 4 GB, und jeder Lauf lädt alles neu. Den Europa-Auszug am Stück rührt
das Skript bewusst nicht an.

## Eigener Server in der App

Wer die Kacheln selbst erzeugt, trägt seinen Server in der App ein: **Navigation,
Kartendaten, Kartenserver**. Anzugeben ist die Adresse, unter der `index.json` und die
Kacheln liegen, etwa `https://example.org/mapdata/`. Die App übernimmt sie nur, wenn sie
dort eine lesbare `index.json` findet; **Standard** setzt auf den BoatSpeedy-Server zurück.
Android lädt ohne Weiteres nur über `https`.

## Lizenz

Die Skripte stehen unter MIT, die **erzeugten Kartendaten unter ODbL**, denn sie stammen aus
OpenStreetMap. Namensnennung „© OpenStreetMap-Mitwirkende" ist Pflicht, und wer die
Kacheln weitergibt, muss das ebenfalls unter ODbL tun. Einzelheiten in [LICENSE](LICENSE).
