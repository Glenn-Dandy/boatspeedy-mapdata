#!/bin/bash
# Menü zur Verwaltung der Kartendaten — direkt auf dem Server, über SSH.
#
# Der bewusst einfache Weg: Ein Adminbereich im Browser bräuchte Anmeldung, einen
# eigenen Dienst und irgendeine Möglichkeit, einen Lauf zu starten — üblicherweise über
# den Docker-Socket, was faktisch Root auf der Maschine bedeutet. Für einen Knopf, der
# vielleicht viermal im Jahr gedrückt wird, ist das ein schlechtes Geschäft.
#
# Aufruf:  ./manage.sh
set -u

cd "$(dirname "$0")"

DATA=data
WORK=build/work
GEO="$WORK/geojson"
LOG=log/build.log

# ── Hilfsmittel ───────────────────────────────────────────────────────────────

running() { [ -n "$(docker ps --filter name=mapdata-build -q 2>/dev/null)" ]; }

human() {  # Bytes → lesbar
    numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0} B"
}

pause() { printf '\n'; read -rp "Weiter mit Eingabetaste… " _; }

regions() { sed 's/#.*//' regions.txt | tr -d ' \t\r' | grep -v '^$'; }

# ── Anzeigen ──────────────────────────────────────────────────────────────────

kopf() {
    local tiles=0 bytes=0 stand="—" pbfs=0 pbfsize=0 web="steht"
    if [ -f "$DATA/index.json" ]; then
        tiles=$(find "$DATA" -name '*.json.gz' | wc -l)
        bytes=$(du -sb "$DATA" 2>/dev/null | cut -f1)
        stand=$(sed -n 's/.*"generated":"\([^"]*\)".*/\1/p' "$DATA/index.json")
    fi
    pbfs=$(find "$WORK" -maxdepth 1 -name '*.osm.pbf' 2>/dev/null | wc -l)
    pbfsize=$(du -sb "$WORK" 2>/dev/null | cut -f1 || echo 0)
    docker ps --filter name=mapdata-web --format '{{.Status}}' | grep -q . && web="läuft"

    printf '\n\033[1mBoatSpeedy — Kartendaten\033[0m\n\n'
    printf '  Kacheln     %s Stück, %s, Stand %s\n' "$tiles" "$(human "$bytes")" "$stand"
    printf '  Auszüge     %s Gebiete, %s\n' "$pbfs" "$(human "$pbfsize")"
    printf '  Gebietsliste %s Einträge\n' "$(regions | wc -l)"
    printf '  Auslieferer %s\n' "$web"
    printf '  Platte      %s frei von %s\n' \
        "$(df -h . | awk 'NR==2{print $4}')" "$(df -h . | awk 'NR==2{print $2}')"
    if running; then
        printf '  \033[33mLauf        aktiv seit %s\033[0m\n' \
            "$(docker ps --filter name=mapdata-build --format '{{.Status}}' | head -1)"
    fi
    printf '\n'
}

einzeln() {
    printf '\n%-28s %10s  %-12s %8s\n' "Gebiet" "Auszug" "geholt am" "Zwischen"
    printf '%s\n' "────────────────────────────────────────────────────────────────"
    local r name pbf geoj size datum zw
    for r in $(regions); do
        name=$(printf '%s' "$r" | tr '/' '_')
        pbf="$WORK/$name.osm.pbf"
        geoj="$GEO/$name.geojsonseq"
        if [ -s "$pbf" ]; then
            size=$(human "$(stat -c %s "$pbf")")
            datum=$(date -d "@$(stat -c %Y "$pbf")" '+%d.%m.%Y' 2>/dev/null)
        else
            # Bewusst ASCII: printf zaehlt Bytes, und ein Gedankenstrich sind drei —
            # die Spalten verrutschen dann genau bei den Zeilen, die auffallen sollen.
            size="-"; datum="-"
        fi
        [ -s "$geoj" ] && zw="ja" || zw="-"
        printf '%-28s %10s  %-12s %8s\n' "${r#europe/}" "$size" "$datum" "$zw"
    done
    printf '\n„Zwischen" = fertig verarbeitet. Ein neuer Lauf überspringt diese Gebiete;\n'
    printf 'zum vollständigen Neuaufbau die Zwischenergebnisse löschen (Punkt 6).\n'
}

# ── Läufe ─────────────────────────────────────────────────────────────────────

starte() {  # $1 = Datei mit Gebieten (leer = die normale Liste)
    if running; then
        printf '\n\033[31mEs läuft bereits einer.\033[0m Zwei gleichzeitig schreiben in dasselbe\n'
        printf 'Arbeitsverzeichnis und zerlegen sich gegenseitig die Daten.\n'
        return 1
    fi
    mkdir -p log "$WORK" "$DATA"
    local mount=""
    [ -n "${1:-}" ] && mount="-v $(readlink -f "$1"):/build/regions.txt:ro"
    # setsid, damit der Lauf weiterläuft, wenn die SSH-Sitzung endet.
    # shellcheck disable=SC2086
    setsid nohup sh -c "docker compose run --rm $mount mapdata-build >> $LOG 2>&1" \
        </dev/null >/dev/null 2>&1 &
    sleep 6
    if running; then
        printf '\n\033[32mLauf gestartet.\033[0m Er läuft weiter, auch wenn du dich abmeldest.\n'
        printf 'Mitlesen mit Punkt 4.\n'
    else
        printf '\n\033[31mLauf nicht angesprungen.\033[0m Letzte Zeilen:\n'
        tail -5 "$LOG" 2>/dev/null | sed 's/^/  /'
    fi
}

ein_gebiet() {
    printf '\nWelches Gebiet? (etwa: germany, netherlands, france)\n'
    read -rp "> " g
    [ -z "$g" ] && return
    local voll="europe/$g"
    if ! regions | grep -qx "$voll"; then
        printf '\n\033[31m%s steht nicht in regions.txt.\033[0m\n' "$voll"
        return
    fi
    # Damit es wirklich neu verarbeitet wird, muss das Zwischenergebnis weg.
    local name; name=$(printf '%s' "$voll" | tr '/' '_')
    rm -f "$GEO/$name.geojsonseq"
    printf '%s\n' "$voll" > /tmp/mapdata-one.txt
    printf '\nHinweis: Die Kacheln werden danach aus **allen** vorhandenen\n'
    printf 'Zwischenergebnissen neu geschnitten, nicht nur aus diesem Gebiet.\n'
    starte /tmp/mapdata-one.txt
}

protokoll() {
    if [ ! -f "$LOG" ]; then
        printf '\nNoch kein Protokoll.\n'
        return
    fi
    printf '\nMit Strg-C zurück ins Menü.\n\n'
    trap ' ' INT
    tail -f "$LOG"
    trap - INT
}

aufraeumen() {
    printf '\n  1) Zwischenergebnisse löschen (%s) — nächster Lauf verarbeitet alles neu\n' \
        "$(du -sh "$GEO" 2>/dev/null | cut -f1 || echo 0)"
    printf '  2) Rohauszüge löschen (%s) — nächster Lauf lädt sie neu herunter\n' \
        "$(du -ch "$WORK"/*.osm.pbf 2>/dev/null | tail -1 | cut -f1 || echo 0)"
    printf '  3) Verwaiste Kacheln löschen (nicht mehr im Verzeichnis genannt)\n'
    printf '  z) Zurück\n\n'
    read -rp "> " w
    case "$w" in
        1) read -rp "Wirklich löschen? [j/N] " j; [ "$j" = j ] && rm -rf "$GEO" && echo "gelöscht" ;;
        2) printf '\n\033[33mDas kostet beim nächsten Lauf mehrere Gigabyte fremder Bandbreite.\033[0m\n'
           read -rp "Wirklich löschen? [j/N] " j
           [ "$j" = j ] && rm -f "$WORK"/*.osm.pbf && echo "gelöscht" ;;
        3) verwaiste ;;
        *) : ;;
    esac
}

verwaiste() {
    [ -f "$DATA/index.json" ] || { printf '\nKein Verzeichnis vorhanden.\n'; return; }
    local n=0 f name
    for f in "$DATA"/*.json.gz; do
        [ -e "$f" ] || continue
        name=$(basename "$f" .json.gz)
        grep -q "\"$name\"" "$DATA/index.json" || { rm -f "$f"; n=$((n + 1)); }
    done
    printf '\n%s verwaiste Kacheln gelöscht.\n' "$n"
}

neustart_web() {
    docker compose up -d --force-recreate mapdata-web >/dev/null 2>&1
    sleep 3
    local port; port=$(grep -E '^MAPDATA_PORT=' .env 2>/dev/null | cut -d= -f2)
    port=${port:-8081}
    printf '\n  /mapdata/healthz     %s\n' \
        "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/mapdata/healthz" || echo '---')"
    printf '  /mapdata/index.json  %s\n' \
        "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/mapdata/index.json" || echo '---')"
    printf '\nNach einem Lauf ist der Neustart nötig, wenn das Datenverzeichnis neu\n'
    printf 'angelegt wurde: Eine Einhängung folgt dem Inode, nicht dem Pfad.\n'
}

# ── Menü ──────────────────────────────────────────────────────────────────────

while true; do
    clear 2>/dev/null || true
    kopf
    cat <<'MENU'
  1) Gebiete im Einzelnen
  2) Lauf starten (alle Gebiete)
  3) Lauf starten (ein Gebiet)
  4) Protokoll mitlesen
  5) Auslieferer neu starten und prüfen
  6) Aufräumen
  q) Beenden
MENU
    printf '\n'
    read -rp "> " wahl
    case "$wahl" in
        1) einzeln; pause ;;
        2) starte ""; pause ;;
        3) ein_gebiet; pause ;;
        4) protokoll ;;
        5) neustart_web; pause ;;
        6) aufraeumen; pause ;;
        q|Q) printf '\n'; exit 0 ;;
        *) : ;;
    esac
done
