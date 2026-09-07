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

### Auffrischen

`./update.sh` erzeugt alles neu und startet den Auslieferer durch. Als Cron-Eintrag
gedacht — **monatlich reicht**, und mehr wäre unhöflich: Jeder Lauf lädt mehrere
Gigabyte von Geofabrik. Wasserwege ändern sich in Monaten kaum; bei Wehren und
Sperrungen reden wir über Jahre.

### Bereits geholte Auszüge

Ein Auszug, der schon auf der Platte liegt und **jünger als 30 Tage** ist, wird
wiederverwendet statt neu geholt. Das ist keine Bequemlichkeit, sondern Rücksicht:
Beim Suchen zweier Fehler kamen an einem Tag vier volle Deutschland-Downloads zusammen,
rund 20 GB — danach wies Geofabriks Proxy jeden weiteren mit einem sofortigen 502 ab und
ein ganzer Europa-Lauf scheiterte an allen Gebieten.

Mit `MAX_AGE_DAYS` lässt sich die Frist ändern, mit `KEEP_PBF=1` bleiben die Auszüge
nach dem Filtern liegen.

### Platzbedarf

Die Gebiete werden **nacheinander** verarbeitet, und jeder Auszug wird sofort nach dem
Filtern gelöscht. Damit liegt die Spitze bei etwa der Größe des größten einzelnen
Auszugs — Deutschland oder Frankreich sind je rund 4 GB. Den Europa-Auszug am Stück
(28 GB) rührt das Skript bewusst nicht an.

## Lizenz

Die Skripte stehen unter MIT, die **erzeugten Kartendaten unter ODbL** — sie stammen aus
OpenStreetMap. Namensnennung „© OpenStreetMap-Mitwirkende" ist Pflicht, und wer die
Kacheln weitergibt, muss das ebenfalls unter ODbL tun. Einzelheiten in [LICENSE](LICENSE).
