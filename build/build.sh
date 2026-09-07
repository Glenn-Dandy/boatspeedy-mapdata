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
python3 /build/tile.py "$OUT" "$WORK/tiles" "$(date -u +%Y-%m-%d)" "$GEO"/*.geojsonseq

rm -rf "$GEO" "$WORK/tiles"
echo
echo "Fertig. Ergebnis liegt in $OUT."
