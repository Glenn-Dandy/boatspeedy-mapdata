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
# So oft wird die Aktualisierung versucht, bevor der alte Auszug genommen wird. Ein
# Netzhaenger bei Geofabrik ist damit erledigt, statt einen ganzen Lauf wertlos zu machen.
UPDATE_TRIES=${UPDATE_TRIES:-3}
UPDATE_PAUSE=${UPDATE_PAUSE:-20}
ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

# Auf welchem Stand ein Auszug ist. Nur der Kopf wird gelesen - eine halbe Sekunde, auch
# bei fuenf Gigabyte. Damit kann jeder Schritt sagen, woran er gerade ist.
stand() {
    osmium fileinfo "$1" 2>/dev/null | awk -F= '
        /osmosis_replication_sequence_number/ { s = $2 }
        /osmosis_replication_timestamp/       { t = $2 }
        END { if (s == "") print "unbekannt"; else printf "%s vom %s", s, t }'
}

mkdir -p "$WORK" "$OUT"
# Halbe Downloads eines abgebrochenen Laufs wegräumen.
rm -f "$WORK"/*.part
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
nicht_aktuell=""
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
        printf '  Stand: %s\n' "$(stand "$pbf")"
        echo "  Aktualisierung: laeuft"
        updated=0
        grund=""
        # **Mehr als ein Versuch, und der Fehler wird nicht weggeworfen.**
        #
        # Vorher ging die Fehlerausgabe nach /dev/null, uebrig blieb "Aktualisierung
        # fehlgeschlagen" ohne Grund — und der Lauf machte mit dem alten Auszug weiter,
        # schnitt alle Kacheln und meldete "Fertig". Von aussen ein geglueckter Lauf, nur
        # ohne neue Daten. Genau das ist passiert: ein voruebergehender Fehler, und
        # niemand konnte sehen, welcher.
        versuch=0
        while [ "$versuch" -lt "$UPDATE_TRIES" ]; do
            versuch=$((versuch + 1))
            if [ "$versuch" -gt 1 ]; then
                printf '  Aktualisierung: Versuch %s von %s\n' "$versuch" "$UPDATE_TRIES"
                sleep "$UPDATE_PAUSE"
            fi
            # Rueckgabe 0 = fertig, 1 = es gibt noch mehr (Groessenbegrenzung erreicht),
            # alles andere ist ein Fehler. Deshalb in Runden, aber nicht endlos.
            round=0
            while [ "$round" -lt 8 ]; do
                round=$((round + 1))
                # `|| rc=$?` ist hier wesentlich: Mit `set -e` wuerde ein Rueckgabewert
                # ungleich null das ganze Skript beenden, und 1 heisst bei diesem Werkzeug
                # nicht "Fehler", sondern "es gibt noch mehr".
                rc=0
                pyosmium-up-to-date --size 2000 -o "$pbf.new" "$pbf" >"$ERRLOG" 2>&1 || rc=$?
                if [ "$rc" -eq 0 ]; then
                    # Rueckgabe 0 heisst "jetzt aktuell" - das schliesst "war schon aktuell"
                    # ein, und dann wird gar keine Ausgabedatei geschrieben. Ein blindes mv
                    # scheitert hier und beendet mit set -e den ganzen Lauf.
                    if [ -s "$pbf.new" ]; then
                        mv -f "$pbf.new" "$pbf"
                    fi
                    rm -f "$pbf.new"
                    updated=1
                    break
                elif [ "$rc" -eq 1 ] && [ -s "$pbf.new" ]; then
                    # Teilstueck angewandt, es fehlt noch etwas - naechste Runde.
                    mv -f "$pbf.new" "$pbf"
                    printf '  Aktualisierung: Teilstueck %s angewandt, es folgt mehr\n' "$round"
                else
                    rm -f "$pbf.new"
                    grund=$(grep -v '^ *$' "$ERRLOG" 2>/dev/null | tail -1 | cut -c1-160)
                    break
                fi
            done
            [ "$updated" = "1" ] && break
        done

        if [ "$updated" = "1" ]; then
            printf '  Aktualisierung: fertig, jetzt %s\n' "$(stand "$pbf")"
        else
            printf '  Aktualisierung: FEHLGESCHLAGEN nach %s Versuchen\n' "$versuch" >&2
            if [ -n "$grund" ]; then printf '  Grund: %s\n' "$grund" >&2; fi
            nicht_aktuell="$nicht_aktuell $region"
            if [ -n "$(find "$pbf" -mtime "+$MAX_AGE_DAYS" 2>/dev/null)" ]; then
                echo "  Auszug ist zu alt - wird neu geholt" >&2
                rm -f "$pbf"
            else
                printf '  Weiter mit dem vorhandenen Auszug (Stand %s)\n' "$(stand "$pbf")" >&2
            fi
        fi
    fi

    if [ ! -s "$pbf" ]; then
    echo "  holen"
    # Hartnäckig, aber geduldig. Geofabrik antwortet unter Last mit 502; mit nur drei
    # Versuchen brach ein Lauf über 48 Gebiete schon beim ersten Schluckauf ab.
    # --retry-all-errors nimmt auch die 502 mit, nicht nur Verbindungsfehler.
    # Erst unter anderem Namen laden, dann umbenennen. Ein abgebrochener Download —
    # Neustart, Netz weg, Strg-C — hinterlaesst sonst eine halbe Datei, die nicht leer
    # ist und deshalb beim naechsten Lauf als gueltiger Auszug durchgeht.
    if ! curl -fsSL --retry 6 --retry-delay 20 --retry-all-errors \
            -o "$pbf.part" "$BASE/$region-latest.osm.pbf"; then
        echo "  FEHLER: $region nicht ladbar — übersprungen" >&2
        failed="$failed $region"
        rm -f "$pbf.part"
        # Ein fehlendes Gebiet ist eine Lücke in der Abdeckung, aber kein Grund, die
        # anderen siebenundvierzig wegzuwerfen. Am Ende steht, was gefehlt hat.
        continue
    fi
    mv -f "$pbf.part" "$pbf"
    printf '  %s\n' "$(du -h "$pbf" | cut -f1) geladen"
    fi

    echo "  Filtern: laeuft"
    # Die Knoten der gefundenen Wege kommen mit, sonst hätten wir Linien ohne Punkte.
    osmium tags-filter --overwrite -o "$small" "$pbf" \
        "$WAYS" "$NODES" "$BARRIERS" "$NOTICES"
    printf '  Filtern: fertig, %s\n' "$(du -h "$small" | cut -f1)"

    # Die Auszüge bleiben **liegen**. Ganz Europa sind rund 28 GB — auf einer 48-GB-Platte
    # tragbar, und der Gegenwert ist, dass ein weiterer Lauf innerhalb des halben Jahres
    # gar nichts mehr herunterlädt. Mit KEEP_PBF=0 werden sie wie früher sofort gelöscht,
    # falls der Platz doch knapp wird.
    [ "${KEEP_PBF:-1}" = "1" ] || rm -f "$pbf"

    echo "  Ausgeben: laeuft"
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

if [ -n "$nicht_aktuell" ]; then
    echo
    echo "== ACHTUNG: nicht aktualisierte Gebiete ==" >&2
    for f in $nicht_aktuell; do echo "  $f" >&2; done
    echo "  Diese wurden aus dem vorhandenen Auszug geschnitten - die Kacheln sind" >&2
    echo "  also unveraendert. Lauf spaeter wiederholen." >&2
fi

if [ -n "$failed" ]; then
    echo
    echo "== ACHTUNG: nicht geladene Gebiete ==" >&2
    for f in $failed; do echo "  $f" >&2; done
    echo "  Dort fehlen Kacheln. Lauf später wiederholen." >&2
fi

echo
echo "== Kacheln schneiden =="
# Mit Uhrzeit, nicht nur mit Datum. Tagesgenau reichte nicht: Laufen an einem Tag zwei
# Laeufe - erst der grosse, abends noch einer fuer ein einzelnes Land -, traegt die
# geaenderte Kachel dasselbe Datum wie vorher, und die App sieht keinen Unterschied. Der
# Vergleich ist ein Zeichenkettenvergleich; ein laengerer Wert ist groesser als das
# blosse Datum, kuerzere Werte aus frueheren Laeufen bleiben also korrekt aelter.
python3 /build/tile.py "$OUT" "$WORK/tiles" "$(date -u +%Y-%m-%dT%H:%MZ)" "$GEO"/*.geojsonseq

# Die Zwischenergebnisse bleiben für den nächsten Aufruf liegen; nur die Kachel-
# Zwischendateien werden aufgeräumt. Wer Platz braucht: rm -rf build/work/geojson
rm -rf "$WORK/tiles"
echo
echo "Fertig. Ergebnis liegt in $OUT."
if [ -n "$failed" ]; then
    echo "Unvollständig — nach dem erneuten Aufruf werden nur die fehlenden Gebiete geholt."
fi
