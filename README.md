# BoatSpeedy — Kartendaten

Wasserwege aus OpenStreetMap, in Kacheln geschnitten, damit die App **offline** routen
kann. Ein nginx im Docker-Container liefert sie aus; erzeugt werden sie von einem
zweiten Container, der nur läuft, wenn man ihn ruft.

Die App selbst liegt in [Glenn-Dandy/BoatSpeedy](https://github.com/Glenn-Dandy/BoatSpeedy).

## Warum das nötig war

Zum Rechnen einer Route muss die App wissen, wo die Wasserwege verlaufen. Bisher fragte
sie das bei jeder Route über die **Overpass-Schnittstelle** an — öffentliche Server, von
aller Welt genutzt und entsprechend oft überlastet. Gemessen am 4. September 2026:

| Server | von fünf gleichen Anfragen |
|---|---|
| `overpass-api.de` | keine Verbindung |
| `overpass.kumi.systems` | zweimal beantwortet, dreimal 504 nach je 40 s |
| `overpass.private.coffee` | zweimal beantwortet, zweimal 504, einmal gar nichts |

Routing scheiterte damit häufiger, als es gelang — und auf dem Wasser, wo es gebraucht
wird, gibt es ohnehin oft kein Netz. Mit den Kacheln wird **einmal** geladen, danach
rechnet das Handy allein.

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

Der Inhalt entspricht dem, was die App von Overpass bekäme — `elements` mit `type`,
`tags` und `geometry`. So liest sie beide Quellen mit demselben Code; nur die Herkunft
wechselt. Enthalten sind Flüsse, Kanäle, Fahrwasser und Bäche, dazu Schleusen, Wehre,
Dämme, Sperrzeichen und die Hinweisschilder mit ihren Geschwindigkeitsangaben.

Wege, die über eine Kachelkante laufen, liegen **vollständig in beiden** Kacheln. Das
kostet etwas Doppelung, dafür passt das Netz beim Zusammensetzen lückenlos zusammen.
Grenzflüsse, die in zwei Länderauszügen vorkommen, werden über ihre OSM-Kennung
entdoppelt.

Dazu ein `index.json` mit allen Kacheln, ihrer Größe und dem Erzeugungsdatum — daran
sieht die App, was es gibt und wie viel ein Download kostet.

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

`./manage.sh` ist ein Menü auf dem Server — Gebiete im Einzelnen ansehen, einen Lauf
starten (alle oder eines), das Protokoll mitlesen, aufräumen, den Auslieferer neu
starten.

Bewusst als Shell-Skript und nicht als Adminbereich im Browser: Ein Knopf im Netz
bräuchte Anmeldung, einen eigenen Dienst und einen Weg, einen Lauf zu starten —
üblicherweise über den Docker-Socket, was faktisch Root auf der Maschine bedeutet. Für
etwas, das ein paar Mal im Jahr gebraucht wird, ist das ein schlechtes Geschäft.

Das Menü weigert sich, einen zweiten Lauf zu starten, solange einer aktiv ist: Zwei
schreiben in dasselbe Arbeitsverzeichnis und zerlegen sich gegenseitig die Daten. Läufe
werden mit `setsid` gestartet und laufen weiter, wenn die Sitzung endet.

### Auffrischen

`./update.sh` erzeugt alles neu und startet den Auslieferer durch. Als Cron-Eintrag
gedacht; wie oft, ist inzwischen keine Kostenfrage mehr (siehe unten).

### Aktualisiert wird, nicht neu geladen

Ein einmal geholter Auszug wird **behalten** und bei jedem weiteren Lauf über
Geofabriks Änderungsstrom auf Stand gebracht, statt neu geladen zu werden. Die Auszüge
tragen im Kopf, wo ihr Strom liegt und auf welchem Stand sie sind
(`osmosis_replication_base_url`, `osmosis_replication_sequence_number`);
`pyosmium-up-to-date` holt daraufhin nur die Tagesdifferenzen.

| | Tagesdifferenz | Vollauszug |
|---|---|---|
| Luxemburg | 21–236 kB | 47 MB |
| Deutschland | 6,2 MB | 4,8 GB |

Bei monatlichem Auffrischen ist das für Deutschland der Faktor siebenundzwanzig. Ganz
Europa liegt damit als rund 28 GB auf der Platte — dafür lädt ein Lauf danach fast
nichts mehr, und die Daten dürfen ruhig öfter frisch geholt werden.

Das ist keine Bequemlichkeit, sondern Rücksicht: Beim Suchen zweier Fehler kamen an
einem Tag vier volle Deutschland-Downloads zusammen, rund 20 GB — danach wies Geofabriks
Proxy jeden weiteren mit einem sofortigen 502 ab, und ein ganzer Europa-Lauf scheiterte
an allen Gebieten.

Scheitert die Aktualisierung, wird der vorhandene Auszug weiterbenutzt — er ist dann nur
älter, nicht kaputt. Erst wenn er die Altersgrenze von `MAX_AGE_DAYS` (180) reißt, wird
doch neu geladen. `KEEP_PBF=0` löscht die Auszüge wie früher sofort nach dem Filtern.

### Wiederaufnahme

Ein abgebrochener Lauf wird beim nächsten Aufruf dort fortgesetzt, wo er stand: Länder
mit vorhandenem Zwischenergebnis werden übersprungen. `FRESH=1` fängt von vorn an.

### Platzbedarf

Die Gebiete werden **nacheinander** verarbeitet, und jeder Auszug wird sofort nach dem
Filtern gelöscht. Damit liegt die Spitze bei etwa der Größe des größten einzelnen
Auszugs — Deutschland oder Frankreich sind je rund 4 GB. Den Europa-Auszug am Stück
(28 GB) rührt das Skript bewusst nicht an.

## Lizenz

Die Skripte stehen unter MIT, die **erzeugten Kartendaten unter ODbL** — sie stammen aus
OpenStreetMap. Namensnennung „© OpenStreetMap-Mitwirkende" ist Pflicht, und wer die
Kacheln weitergibt, muss das ebenfalls unter ODbL tun. Einzelheiten in [LICENSE](LICENSE).
