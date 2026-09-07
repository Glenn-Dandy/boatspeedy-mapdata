#!/bin/sh
# Baut aus OpenStreetMap-Auszügen die Kacheln, die die App lädt.
#
# Ablauf je Gebiet: Auszug holen -> auf Wasserwege filtern -> als GeoJSON ausgeben
# -> Auszug wieder löschen. Nacheinander, nicht parallel: Der Auszug für Frankreich
# oder Deutschland ist je rund vier Gigabyte, und die Platte hat vierzehn. Erst wenn
# alle Gebiete durch sind, entstehen daraus die Kacheln.
#
# Der Europa-Auszug am Stück (28 GB) wird bewusst nicht angefasst.
set -eu

WORK=${WORK:-/work}
OUT=${OUT:-/out}
REGIONS=${REGIONS:-/build/regions.txt}
BASE=${BASE:-https://download.geofabrik.de}
# Ab diesem Alter wird ein liegengebliebener Auszug neu geholt. Ein Monat passt zum
# Auffrischrhythmus: Der nächste geplante Lauf holt ohnehin neu, und alles dazwischen —
# Filteränderungen, Fehlersuche, ein zweiter Anlauf nach einem Ausfall — kostet keine
# fremde Bandbreite mehr.
MAX_AGE_DAYS=${MAX_AGE_DAYS:-30}

mkdir -p "$WORK" "$OUT"
GEO="$WORK/geojson"
rm -rf "$GEO" "$WORK/tiles"
mkdir -p "$GEO"

# Was uns interessiert. **Ohne Bäche.** Sie waren eine Zeit lang dabei, weil ein Kanu
# sie theoretisch benutzen könnte — praktisch ist kaum einer befahrbar, und sie machten
# 800.249 von 871.907 Objekten aus: 87 % der Datenmenge für den seltensten Fall.
# Deutschland schrumpft ohne sie von 53 auf rund 7 MB.
#
# Welches Fahrzeug unterwegs ist, entscheidet **nicht** über die Gewässerart, sondern
# nur darüber, welche Verbote gelten (boat=no, motorboat=no, canoe=no) — und das wertet
# die App aus den Merkmalen aus, die hier ohnehin mitkommen.
WAYS='w/waterway=river,canal,fairway'
# Was den Weg versperrt, und die Hinweiszeichen mit ihren Werten.
NODES='n/waterway=lock_gate,weir,dam,sluice_gate'
BARRIERS='n/barrier=no_entry,prohibition,lock_gate'
# Alle Seezeichen, nicht nur die Hinweistafeln: Tonnen, Baken, Feuer, Sperrgebiete.
# Damit kann die App sie antippbar machen, ohne dafür ins Netz zu gehen — die Kacheln
# von OpenSeaMap zeichnen sie zwar, sind aber Bilder ohne Werte.
NOTICES='n/seamark:type'

count=0
failed=""
while IFS= read -r line; do
    region=$(printf '%s' "$line" | sed 's/#.*//' | tr -d ' \t\r')
    [ -z "$region" ] && continue

    name=$(printf '%s' "$region" | tr '/' '_')
    pbf="$WORK/$name.osm.pbf"
    small="$WORK/$name.water.pbf"

    echo "== $region =="
    # Einen Auszug, der schon daliegt und nicht zu alt ist, nicht noch einmal holen.
    #
    # Ohne das kostet jede Änderung am Filter einen vollen Download. Beim Entwickeln
    # sind so an einem Tag viermal 4,8 GB Deutschland zusammengekommen — danach wies
    # Geofabriks Proxy jeden weiteren Download mit 502 ab, und der Europa-Lauf scheiterte
    # an allen Gebieten. Es ist fremde Bandbreite; sie ist zu schonen.
    if [ -s "$pbf" ] && [ -z "$(find "$pbf" -mtime "+$MAX_AGE_DAYS" 2>/dev/null)" ]; then
        printf '  %s liegt schon da (%s), wird wiederverwendet\n' \
            "$region" "$(du -h "$pbf" | cut -f1)"
    else
    echo "  holen"
    # Hartnäckig, aber geduldig. Geofabrik antwortet unter Last mit 502; mit nur drei
    # Versuchen brach ein Lauf über 48 Gebiete schon beim ersten Schluckauf ab.
    # --retry-all-errors nimmt auch die 502 mit, nicht nur Verbindungsfehler.
    if ! curl -fsSL --retry 6 --retry-delay 20 --retry-all-errors \
            -o "$pbf" "$BASE/$region-latest.osm.pbf"; then
        echo "  FEHLER: $region nicht ladbar — übersprungen" >&2
        failed="$failed $region"
        rm -f "$pbf"
        # Ein fehlendes Gebiet ist eine Lücke in der Abdeckung, aber kein Grund, die
        # anderen siebenundvierzig wegzuwerfen. Am Ende steht, was gefehlt hat.
        continue
    fi
    printf '  %s\n' "$(du -h "$pbf" | cut -f1) geladen"
    fi

    echo "  filtern"
    # Die Knoten der gefundenen Wege kommen mit, sonst hätten wir Linien ohne Punkte.
    osmium tags-filter --overwrite -o "$small" "$pbf" \
        "$WAYS" "$NODES" "$BARRIERS" "$NOTICES"
    printf '  %s\n' "$(du -h "$small" | cut -f1) nach dem Filtern"

    # Der große Auszug wird sonst sofort gelöscht — sonst läuft die Platte beim zweiten
    # oder dritten Gebiet voll. Mit KEEP_PBF=1 bleibt er liegen; das ist für das
    # Entwickeln gedacht, wo sonst jede Filteränderung Gigabyte kostet.
    [ "${KEEP_PBF:-0}" = "1" ] || rm -f "$pbf"

    echo "  ausgeben"
    osmium export --overwrite -f geojsonseq --add-unique-id=type_id \
        -o "$GEO/$name.geojsonseq" "$small"
    rm -f "$small"

    count=$((count + 1))
    # Kurz durchatmen zwischen den Gebieten – es ist fremde Bandbreite.
    sleep 5
done < "$REGIONS"

if [ "$count" -eq 0 ]; then
    echo "Keine Gebiete in $REGIONS — nichts zu tun." >&2
    exit 1
fi

if [ -n "$failed" ]; then
    echo
    echo "== ACHTUNG: nicht geladene Gebiete ==" >&2
    for f in $failed; do echo "  $f" >&2; done
    echo "  Dort fehlen Kacheln. Lauf später wiederholen." >&2
fi

echo
echo "== Kacheln schneiden =="
python3 /build/tile.py "$OUT" "$WORK/tiles" "$(date -u +%Y-%m-%d)" "$GEO"/*.geojsonseq

rm -rf "$GEO" "$WORK/tiles"
echo
echo "Fertig. Ergebnis liegt in $OUT."
