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

mkdir -p "$WORK" "$OUT"
GEO="$WORK/geojson"
rm -rf "$GEO"
mkdir -p "$GEO"

# Was uns interessiert. Bäche sind dabei, weil das Kanu sie benutzen darf — ein
# Motorboot nicht, aber das entscheidet die App anhand der Merkmale, nicht wir hier.
WAYS='w/waterway=river,canal,fairway,stream'
# Was den Weg versperrt, und die Hinweiszeichen mit ihren Werten.
NODES='n/waterway=lock_gate,weir,dam,sluice_gate'
BARRIERS='n/barrier=no_entry,prohibition,lock_gate'
NOTICES='n/seamark:notice:category'

count=0
while IFS= read -r line; do
    region=$(printf '%s' "$line" | sed 's/#.*//' | tr -d ' \t\r')
    [ -z "$region" ] && continue

    name=$(printf '%s' "$region" | tr '/' '_')
    pbf="$WORK/$name.osm.pbf"
    small="$WORK/$name.water.pbf"

    echo "== $region =="
    echo "  holen"
    # --location trust: Geofabrik leitet auf die datierte Datei um.
    curl -fsSL --retry 3 --retry-delay 10 -o "$pbf" "$BASE/$region-latest.osm.pbf"
    printf '  %s\n' "$(du -h "$pbf" | cut -f1) geladen"

    echo "  filtern"
    # Die Knoten der gefundenen Wege kommen mit, sonst hätten wir Linien ohne Punkte.
    osmium tags-filter --overwrite -o "$small" "$pbf" \
        "$WAYS" "$NODES" "$BARRIERS" "$NOTICES"
    printf '  %s\n' "$(du -h "$small" | cut -f1) nach dem Filtern"

    # Der große Auszug wird sofort gelöscht — er wird nicht mehr gebraucht, und ohne
    # das läuft die Platte beim zweiten oder dritten Gebiet voll.
    rm -f "$pbf"

    echo "  ausgeben"
    osmium export --overwrite -f geojsonseq --add-unique-id=type_id \
        -o "$GEO/$name.geojsonseq" "$small"
    rm -f "$small"

    count=$((count + 1))
done < "$REGIONS"

if [ "$count" -eq 0 ]; then
    echo "Keine Gebiete in $REGIONS — nichts zu tun." >&2
    exit 1
fi

echo
echo "== Kacheln schneiden =="
python3 /build/tile.py "$OUT" "$(date -u +%Y-%m-%d)" "$GEO"/*.geojsonseq

rm -rf "$GEO"
echo
echo "Fertig. Ergebnis liegt in $OUT."
