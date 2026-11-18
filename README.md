# BoatSpeedy Kartendaten

Wasserwege aus OpenStreetMap als Kacheln, aus denen
[BoatSpeedy](https://github.com/Glenn-Dandy/BoatSpeedy) seine Routen rechnet, dazu
Schifffahrtsmeldungen und Betriebszeiten der Schleusen von ELWIS. Ein nginx im
Docker-Container liefert alles aus.

## Aufbau

```
regions.txt            welche Gebiete eingelesen werden
build/build.sh         holen -> filtern -> ausgeben
build/tile.py          in Kacheln schneiden
nts/nts.py             Schifffahrtsmeldungen von ELWIS holen
locks/locks.py         Betriebszeiten der Schleusen von ELWIS holen
nginx/default.conf     Auslieferung
data/                  Ergebnis (nicht im Repo)
```

### Die Kacheln

Ein Grad breit und hoch, benannt nach der Südwestecke: `n50e011.json.gz`. Der Inhalt hat
dasselbe Format wie eine Overpass-Antwort (`elements` mit `type`, `tags`, `geometry`).
Enthalten sind:

- Flüsse, Kanäle und Fahrwasser, ohne Bäche
- Schleusen (`lock=yes`, `seamark:type=lock_basin`) mit ihren Toren
- Wehre, Dämme und Sperrzeichen
- Umtragewege, Ein- und Ausstiege, Slipanlagen
- Wasserkraftanlagen
- alle Seezeichen samt ihrer `seamark:`-Merkmale

Wege über eine Kachelkante liegen vollständig in beiden Kacheln. `index.json` listet alle
Kacheln mit Größe und Stand.

## Betrieb

```bash
git clone git@github.com:Glenn-Dandy/boatspeedy-mapdata.git
cd boatspeedy-mapdata
cp .env.example .env
docker compose run --rm mapdata-build     # dauert, je nach Gebiet
docker compose up -d mapdata-web mapdata-nts mapdata-locks
```

Der Auslieferer horcht auf Port 8081:

```bash
curl http://127.0.0.1:8081/healthz            # ok
curl http://127.0.0.1:8081/index.json         # Verzeichnis der Kacheln
curl http://127.0.0.1:8081/mapdata/nts.json   # Schifffahrtsmeldungen
curl http://127.0.0.1:8081/mapdata/locks.json # Betriebszeiten der Schleusen
```

Von außen über den Reverse-Proxy, als Unterpfad `/mapdata/`.

### Verwalten

`./manage.sh` ist ein Menü auf dem Server: Auffrischen (nur die Änderungen seit dem
letzten Lauf), einzelne Gebiete auffrischen, neu aufbauen, Läufe ansehen und abbrechen.
Es startet keinen zweiten Lauf, solange einer aktiv ist. Ohne Menü, etwa aus Cron:
`./update.sh`.

Geholte Auszüge bleiben liegen und werden über Geofabriks Änderungsstrom aktualisiert
(`pyosmium-up-to-date`), statt neu geladen zu werden. Ganz Europa braucht so rund 28 GB.
Scheitert die Aktualisierung, wird der alte Auszug benutzt, ab `MAX_AGE_DAYS` (180) neu
geladen. `KEEP_PBF=0` löscht die Auszüge nach dem Filtern.

Ein abgebrochener Lauf macht beim nächsten Aufruf weiter, `FRESH=1` fängt von vorn an.

## Schifffahrtsmeldungen

`mapdata-nts` holt alle 30 Minuten die Nachrichten für die Binnenschifffahrt von
[ELWIS](https://www.elwis.de): Sperrungen und Einschränkungen an Bundeswasserstraßen für
heute und die nächsten sieben Tage. Ergebnis: `data/nts.json.gz`, rund 70 kB.

## Betriebszeiten der Schleusen

`mapdata-locks` holt einmal am Tag die Betriebszeiten der Schleusen an
Bundeswasserstraßen von
[ELWIS](https://www.elwis.de/DE/dynamisch/Schleuseninformationen/), eine Seite je
Schleuse mit einer Sekunde Pause. Ein Lauf dauert gut zehn Minuten. Die Seiten nennen
keine Koordinaten, die Lage kommt über den Namen und die Wasserstraße aus den Kacheln.
Rund 490 von 535 Schleusen finden so ihren Platz. Ergebnis: `data/locks.json.gz`.

```bash
docker compose logs mapdata-nts mapdata-locks
```

## Eigener Server in der App

In der App unter **Navigation, Kartendaten, Kartenserver** die Adresse eintragen, unter der
`index.json` liegt, etwa `https://example.org/mapdata/`. Nur `https`.

## Lizenz

Skripte unter MIT. Die erzeugten Kartendaten stehen unter ODbL, „© OpenStreetMap-Mitwirkende“.
Schifffahrtsmeldungen und Betriebszeiten der Schleusen: ELWIS (Quelle: www.elwis.de),
unverändert übernommen. Einzelheiten in [LICENSE](LICENSE).
