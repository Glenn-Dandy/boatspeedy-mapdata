#!/bin/bash
# Menü zur Verwaltung der Kartendaten — direkt auf dem Server, über SSH.
#
# Der bewusst einfache Weg: Ein Adminbereich im Browser bräuchte Anmeldung, einen
# eigenen Dienst und irgendeine Möglichkeit, einen Lauf zu starten — üblicherweise über
# den Docker-Socket, was faktisch Root auf der Maschine bedeutet. Für einen Knopf, der
# vielleicht viermal im Jahr gedrückt wird, ist das ein schlechtes Geschäft.
#
# Geordnet nach dem, was man vorhat — nicht danach, wie es innen gebaut ist. Eine erste
# Fassung hatte "Lauf starten" und "Aufräumen" getrennt, obwohl man für ein einzelnes
# Land beides brauchte; das war von außen nicht zu erraten.
#
# Aufruf:  ./manage.sh
set -u

cd "$(dirname "$0")"

DATA=data
WORK=build/work
GEO="$WORK/geojson"
LOG=log/build.log

B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'

# ── Zustand ───────────────────────────────────────────────────────────────────

running() { [ -n "$(docker ps --filter name=mapdata-build -q 2>/dev/null)" ]; }
regions() { sed 's/#.*//' regions.txt | tr -d ' \t\r' | grep -v '^$'; }
human()   { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# Wie weit ist der laufende Vorgang? Gezählt wird an den Überschriften im Protokoll.
fortschritt() {
    local total done_ current
    total=$(regions | wc -l)
    done_=$(grep -c '^== europe/' "$LOG" 2>/dev/null || echo 0)
    current=$(grep '^== europe/' "$LOG" 2>/dev/null | tail -1 | sed 's/^== //; s/ ==$//')
    printf '%s|%s|%s' "$done_" "$total" "${current:-—}"
}

schritt() {  # die letzte inhaltliche Zeile, ohne Docker-Geplapper
    grep -vE '^ (Container|Network|Image)|^#[0-9]|^ *$' "$LOG" 2>/dev/null | tail -1 | sed 's/^ *//'
}

kopf() {
    local tiles=0 bytes=0 stand="—" pbfs pbfsize web="steht"
    if [ -f "$DATA/index.json" ]; then
        tiles=$(find "$DATA" -name '*.json.gz' | wc -l)
        bytes=$(du -sb "$DATA" 2>/dev/null | cut -f1)
        stand=$(sed -n 's/.*"generated":"\([^"]*\)".*/\1/p' "$DATA/index.json")
    fi
    pbfs=$(find "$WORK" -maxdepth 1 -name '*.osm.pbf' 2>/dev/null | wc -l)
    pbfsize=$(du -sb "$WORK" 2>/dev/null | cut -f1 || echo 0)
    docker ps --filter name=mapdata-web --format '{{.Status}}' | grep -q . && web="läuft"

    printf '\n %sBoatSpeedy — Kartendaten%s\n\n' "$B" "$N"
    printf '   Ausgeliefert   %s Kacheln, %s, Stand %s\n' "$tiles" "$(human "$bytes")" "$stand"
    printf '   Auslieferer    %s\n' "$web"
    printf '   Rohdaten       %s von %s Gebieten, %s\n' \
        "$pbfs" "$(regions | wc -l)" "$(human "$pbfsize")"
    printf '   Platte         %s frei\n' "$(df -h . | awk 'NR==2{print $4}')"

    if running; then
        local f d t c
        f=$(fortschritt); d=${f%%|*}; t=$(printf '%s' "$f" | cut -d'|' -f2); c=${f##*|}
        printf '\n   %sLäuft%s  %s von %s Gebieten — %s\n' "$Y" "$N" "$d" "$t" "$c"
        printf '   %s%s%s\n' "$DIM" "$(schritt)" "$N"
    fi
    printf '\n'
}

# ── Läufe ─────────────────────────────────────────────────────────────────────

starte() {  # $1 = optionale Gebietsdatei
    if running; then
        printf '\n %sEs läuft schon einer.%s Zwei gleichzeitig schreiben in dasselbe\n' "$R" "$N"
        printf ' Arbeitsverzeichnis und zerlegen sich gegenseitig die Daten.\n'
        return 1
    fi
    mkdir -p log "$WORK" "$DATA"
    # Frisches Protokoll je Lauf, das vorige bleibt als .1 liegen — sonst zählt der
    # Fortschritt die Überschriften des letzten Laufs mit.
    [ -f "$LOG" ] && mv -f "$LOG" "$LOG.1"
    local mount=""
    [ -n "${1:-}" ] && mount="-v $(readlink -f "$1"):/build/regions.txt:ro"
    # shellcheck disable=SC2086
    setsid nohup sh -c "docker compose run --rm $mount mapdata-build > $LOG 2>&1" \
        </dev/null >/dev/null 2>&1 &
    sleep 6
    if running; then
        printf '\n %sGestartet.%s Läuft weiter, auch wenn du dich abmeldest.\n' "$G" "$N"
        printf ' Zusehen mit Punkt 4.\n'
    else
        printf '\n %sNicht angesprungen.%s Letzte Zeilen:\n' "$R" "$N"
        tail -5 "$LOG" 2>/dev/null | sed 's/^/   /'
    fi
}

auffrischen() {
    printf '\n %sAlles auffrischen%s\n\n' "$B" "$N"
    printf ' Holt für jedes Gebiet nur die Änderungen seit dem letzten Mal und baut\n'
    printf ' die Kacheln neu. Der übliche Fall.\n\n'
    printf ' Bereits verarbeitete Gebiete werden übersprungen — für einen wirklichen\n'
    printf ' Neuaufbau ist Punkt 3 zuständig.\n\n'
    read -rp " Starten? [j/N] " j
    [ "$j" = j ] || return
    rm -rf "$GEO"      # sonst überspringt er alles und baut nur die Kacheln neu
    starte ""
}

ein_land() {
    printf '\n %sEin Land neu bauen%s\n\n' "$B" "$N"
    printf ' Für den Fall, dass eines gefehlt hat oder veraltet ist. Das Land wird neu\n'
    printf ' geholt und verarbeitet; die anderen bleiben, wie sie sind.\n\n'
    printf ' %sDie Kacheln entstehen danach aus allen Gebieten neu — das dauert auch\n' "$DIM"
    printf ' dann eine Weile, wenn nur ein Land verarbeitet wurde.%s\n\n' "$N"
    printf ' Verfügbar: %s\n\n' "$(regions | sed 's|europe/||' | tr '\n' ' ' | fold -sw 68 | sed '2,$s/^/            /')"
    read -rp " Welches? (leer = zurück) " g
    [ -z "$g" ] && return
    local voll="europe/$g"
    if ! regions | grep -qx "$voll"; then
        printf '\n %s%s steht nicht in der Gebietsliste.%s\n' "$R" "$voll" "$N"
        return
    fi
    rm -f "$GEO/$(printf '%s' "$voll" | tr '/' '_').geojsonseq"
    printf '%s\n' "$voll" > /tmp/mapdata-one.txt
    starte /tmp/mapdata-one.txt
}

neuaufbau() {
    printf '\n %sKomplett neu aufbauen%s\n\n' "$B" "$N"
    printf ' Verwirft alle Zwischenergebnisse und verarbeitet jedes Gebiet von vorn.\n'
    printf ' %sDauert Stunden.%s Die Rohdaten bleiben erhalten, es wird also nichts\n' "$Y" "$N"
    printf ' neu heruntergeladen — nur neu gefiltert und geschnitten.\n\n'
    printf ' Nötig, wenn sich am Filter oder am Kachelformat etwas geändert hat.\n\n'
    read -rp " Wirklich? [j/N] " j
    [ "$j" = j ] || return
    rm -rf "$GEO"
    starte ""
}

zusehen() {
    if [ ! -f "$LOG" ]; then printf '\n Noch kein Protokoll.\n'; return; fi
    printf '\n %sMit Strg-C zurück ins Menü.%s\n' "$DIM" "$N"
    trap ' ' INT
    while true; do
        clear 2>/dev/null || true
        local f d t c
        f=$(fortschritt); d=${f%%|*}; t=$(printf '%s' "$f" | cut -d'|' -f2); c=${f##*|}
        if running; then
            printf '\n %sLäuft%s — %s von %s Gebieten\n\n' "$Y" "$N" "$d" "$t"
            # Ein Balken sagt mehr als eine Zahl.
            local width=50 filled
            filled=$(( t > 0 ? d * width / t : 0 ))
            printf ' ['
            printf '%0.s#' $(seq 1 "$filled") 2>/dev/null
            printf '%0.s·' $(seq 1 $((width - filled))) 2>/dev/null
            printf ']  %s\n\n' "$c"
        else
            printf '\n %sKein Lauf aktiv.%s Letzter Stand:\n\n' "$G" "$N"
        fi
        printf ' %sletzte Zeilen:%s\n' "$DIM" "$N"
        grep -vE '^ (Container|Network|Image)|^#[0-9]' "$LOG" 2>/dev/null | tail -12 | sed 's/^/   /'
        printf '\n %sStrg-C beendet die Ansicht (nicht den Lauf).%s\n' "$DIM" "$N"
        sleep 3
    done
    trap - INT
}

# ── Einzelnes ─────────────────────────────────────────────────────────────────

einzeln() {
    printf '\n %-26s %9s %11s %9s\n' "Gebiet" "Rohdaten" "geholt am" "verarbeitet"
    printf ' %s\n' "──────────────────────────────────────────────────────────"
    local r name pbf geoj size datum zw
    for r in $(regions); do
        name=$(printf '%s' "$r" | tr '/' '_')
        pbf="$WORK/$name.osm.pbf"; geoj="$GEO/$name.geojsonseq"
        if [ -s "$pbf" ]; then
            size=$(human "$(stat -c %s "$pbf")")
            datum=$(date -d "@$(stat -c %Y "$pbf")" '+%d.%m.%Y' 2>/dev/null)
        else
            # ASCII: printf zählt Bytes, ein Gedankenstrich sind drei — die Spalten
            # verrutschen sonst genau bei den Zeilen, die auffallen sollen.
            size="-"; datum="-"
        fi
        [ -s "$geoj" ] && zw="ja" || zw="-"
        printf ' %-26s %9s %11s %9s\n' "${r#europe/}" "$size" "$datum" "$zw"
    done
    printf '\n %sOhne Rohdaten wird beim nächsten Lauf neu geladen; mit Rohdaten nur\n' "$DIM"
    printf ' die Änderungen geholt.%s\n' "$N"
}

pruefen() {
    printf '\n Auslieferer wird neu gestartet…\n'
    docker compose up -d --force-recreate mapdata-web >/dev/null 2>&1
    sleep 3
    local port; port=$(grep -E '^MAPDATA_PORT=' .env 2>/dev/null | cut -d= -f2); port=${port:-8081}
    local a b
    a=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/mapdata/healthz" || echo '---')
    b=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/mapdata/index.json" || echo '---')
    printf '\n   /mapdata/healthz      %s\n   /mapdata/index.json   %s\n' "$a" "$b"
    [ "$a$b" = "200200" ] && printf '\n %sAlles in Ordnung.%s\n' "$G" "$N" \
                          || printf '\n %sEtwas stimmt nicht.%s\n' "$R" "$N"
    printf '\n %sNach einem Lauf ist der Neustart nötig, wenn das Datenverzeichnis neu\n' "$DIM"
    printf ' angelegt wurde: Eine Einhängung folgt dem Inode, nicht dem Pfad.%s\n' "$N"
}

platz() {
    local geo pbf
    geo=$(du -sh "$GEO" 2>/dev/null | cut -f1); geo=${geo:-0}
    pbf=$(du -ch "$WORK"/*.osm.pbf 2>/dev/null | tail -1 | cut -f1); pbf=${pbf:-0}
    printf '\n %sPlatz freigeben%s        %s frei\n\n' "$B" "$N" "$(df -h . | awk 'NR==2{print $4}')"
    printf '   1) Zwischenergebnisse   %-8s  gefahrlos, nächster Lauf macht sie neu\n' "$geo"
    printf '   2) Rohdaten             %-8s  %skostet beim nächsten Lauf Gigabyte%s\n' "$pbf" "$Y" "$N"
    printf '   3) Verwaiste Kacheln              Reste alter Läufe\n'
    printf '   z) Zurück\n\n'
    read -rp " > " w
    case "$w" in
        1) read -rp " Löschen? [j/N] " j; [ "$j" = j ] && rm -rf "$GEO" && printf ' gelöscht\n' ;;
        2) printf '\n %sDann werden beim nächsten Lauf alle Auszüge neu heruntergeladen —\n' "$Y"
           printf ' zusammen rund 28 GB von Geofabrik. Genau das hat uns schon einmal\n'
           printf ' eine Sperre eingebracht.%s\n\n' "$N"
           read -rp " Trotzdem löschen? [j/N] " j
           [ "$j" = j ] && rm -f "$WORK"/*.osm.pbf && printf ' gelöscht\n' ;;
        3) verwaiste ;;
        *) : ;;
    esac
}

verwaiste() {
    [ -f "$DATA/index.json" ] || { printf '\n Kein Verzeichnis vorhanden.\n'; return; }
    local n=0 f name
    for f in "$DATA"/*.json.gz; do
        [ -e "$f" ] || continue
        name=$(basename "$f" .json.gz)
        grep -q "\"$name\"" "$DATA/index.json" || { rm -f "$f"; n=$((n + 1)); }
    done
    printf '\n %s verwaiste Kacheln gelöscht.\n' "$n"
}

# ── Menü ──────────────────────────────────────────────────────────────────────

while true; do
    clear 2>/dev/null || true
    kopf
    printf '   1  %sAuffrischen%s        nur Änderungen holen, Kacheln neu\n' "$B" "$N"
    printf '   2  %sEin Land%s           eines neu holen und verarbeiten\n' "$B" "$N"
    printf '   3  %sNeu aufbauen%s       alles von vorn, ohne Download (Stunden)\n' "$B" "$N"
    printf '\n'
    printf '   4  %sZusehen%s            Fortschritt des laufenden Vorgangs\n' "$B" "$N"
    printf '   5  %sGebiete%s            was liegt da, wie alt\n' "$B" "$N"
    printf '\n'
    printf '   6  Auslieferer prüfen und neu starten\n'
    printf '   7  Platz freigeben\n'
    printf '   q  Beenden\n\n'
    read -rp " > " wahl
    case "$wahl" in
        1) auffrischen; read -rp $'\n Weiter mit Eingabetaste… ' _ ;;
        2) ein_land;    read -rp $'\n Weiter mit Eingabetaste… ' _ ;;
        3) neuaufbau;   read -rp $'\n Weiter mit Eingabetaste… ' _ ;;
        4) zusehen ;;
        5) einzeln;     read -rp $'\n Weiter mit Eingabetaste… ' _ ;;
        6) pruefen;     read -rp $'\n Weiter mit Eingabetaste… ' _ ;;
        7) platz;       read -rp $'\n Weiter mit Eingabetaste… ' _ ;;
        q|Q) printf '\n'; exit 0 ;;
        *) : ;;
    esac
done
