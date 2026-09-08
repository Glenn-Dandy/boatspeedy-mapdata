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
# Ab diesem Alter wird ein liegengebliebener Auszug neu geholt — und erst dann. Ein
# halbes Jahr ist reichlich, aber angemessen: Wasserwege ändern sich in Monaten kaum,
# bei Wehren und Schleusen reden wir über Jahre. Alles darunter — Filteränderungen,
# Fehlersuche, ein zweiter Anlauf nach einem Ausfall, auch ein monatlicher Cron-Lauf —
# kostet damit keine fremde Bandbreite mehr.
MAX_AGE_DAYS=${MAX_AGE_DAYS:-180}

mkdir -p "$WORK" "$OUT"
GEO="$WORK/geojson"
# Die Zwischenergebnisse der Länder bleiben **liegen**. Damit ist der Lauf
# wiederaufnehmbar: Bricht er bei Land dreißig ab — Netz weg, Sperre, Neustart —, macht
# der nächste Aufruf bei Land dreißig weiter, statt die neunundzwanzig davor noch einmal
# zu holen und zu filtern. Mit FRESH=1 fängt er von vorn an.
[ "${FRESH:-0}" = "1" ] && rm -rf "$GEO"
rm -rf "$WORK/tiles"
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
    # Schon fertig verarbeitet? Dann überspringen. Das ist der Kern der Wiederaufnahme.
    if [ -s "$GEO/$name.geojsonseq" ]; then
        printf '  bereits verarbeitet (%s), übersprungen\n' \
            "$(du -h "$GEO/$name.geojsonseq" | cut -f1)"
        count=$((count + 1))
        continue
    fi
    # Liegt der Auszug schon da, wird er **aktualisiert statt neu geholt**.
    #
    # Die Auszüge tragen im Kopf, wo ihr Änderungsstrom liegt und auf welchem Stand sie
    # sind (osmosis_replication_base_url und -sequence_number) — pyosmium-up-to-date holt
    # damit nur die Tagesdifferenzen. Für Deutschland sind das 6 MB je Tag gegen 4,8 GB
    # Vollauszug: bei monatlichem Auffrischen der Faktor siebenundzwanzig.
    #
    # Scheitert das, ist der vorhandene Auszug immer noch brauchbar, nur älter. Erst wenn
    # er die Altersgrenze reißt, wird neu geladen.
    if [ -s "$pbf" ]; then
        echo "  auf Stand bringen"
        updated=0
        # Rückgabe 0 = fertig, 1 = es gibt noch mehr (Größenbegrenzung erreicht),
        # alles andere ist ein Fehler. Deshalb in Runden, aber nicht endlos.
        round=0
        while [ "$round" -lt 8 ]; do
            round=$((round + 1))
            # `|| rc=$?` ist hier wesentlich: Mit `set -e` würde ein Rückgabewert
            # ungleich null das ganze Skript beenden, und 1 heißt bei diesem Werkzeug
            # nicht „Fehler", sondern „es gibt noch mehr".
            rc=0
            pyosmium-up-to-date --size 2000 -o "$pbf.new" "$pbf" >/dev/null 2>&1 || rc=$?
            if [ "$rc" -eq 0 ]; then
                mv -f "$pbf.new" "$pbf"
                updated=1
                break
            elif [ "$rc" -eq 1 ] && [ -s "$pbf.new" ]; then
                # Teilstück angewandt, es fehlt noch etwas — nächste Runde.
                mv -f "$pbf.new" "$pbf"
            else
                rm -f "$pbf.new"
                break
            fi
        done

        if [ "$updated" = "1" ]; then
            printf '  aktuell (%s), kein Vollauszug nötig\n' "$(du -h "$pbf" | cut -f1)"
        elif [ -n "$(find "$pbf" -mtime "+$MAX_AGE_DAYS" 2>/dev/null)" ]; then
            echo "  Aktualisierung fehlgeschlagen und zu alt — wird neu geholt" >&2
            rm -f "$pbf"
        else
            echo "  Aktualisierung fehlgeschlagen, vorhandener Auszug wird genommen" >&2
        fi
    fi

    if [ ! -s "$pbf" ]; then
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

    # Die Auszüge bleiben **liegen**. Ganz Europa sind rund 28 GB — auf einer 48-GB-Platte
    # tragbar, und der Gegenwert ist, dass ein weiterer Lauf innerhalb des halben Jahres
    # gar nichts mehr herunterlädt. Mit KEEP_PBF=0 werden sie wie früher sofort gelöscht,
    # falls der Platz doch knapp wird.
    [ "${KEEP_PBF:-1}" = "1" ] || rm -f "$pbf"

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

# Die Zwischenergebnisse bleiben für den nächsten Aufruf liegen; nur die Kachel-
# Zwischendateien werden aufgeräumt. Wer Platz braucht: rm -rf build/work/geojson
rm -rf "$WORK/tiles"
echo
echo "Fertig. Ergebnis liegt in $OUT."
if [ -n "$failed" ]; then
    echo "Unvollständig — nach dem erneuten Aufruf werden nur die fehlenden Gebiete geholt."
fi
