#!/bin/bash
# Verwaltung der Kartendaten — als Kastenoberfläche im Terminal.
#
# Bewusst kein Adminbereich im Browser: Der bräuchte Anmeldung, einen eigenen Dienst und
# einen Weg, Läufe zu starten — üblicherweise über den Docker-Socket, was faktisch Root
# auf der Maschine bedeutet. Für etwas, das ein paar Mal im Jahr gebraucht wird, ist das
# ein schlechtes Geschäft.
#
# Benutzt `dialog`, wenn vorhanden — dann reagieren die Menüs auch auf die Maus —, sonst
# `whiptail`, das auf Debian ohnehin dabei ist.  Für die Maus:  sudo apt install dialog
#
# Aufruf:  ./manage.sh
set -u

# Ohne UTF-8 zerfallen Umlaute, Haken und Balken in Einzelbytes, und whiptail verrechnet
# sich bei den Spaltenbreiten — auf dem Server steht LANG=C. C.UTF-8 ist auf Debian
# immer da und braucht keine erzeugten Sprachdateien.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

cd "$(dirname "$0")"

DATA=data
WORK=build/work
GEO="$WORK/geojson"
LOG=log/build.log

if command -v dialog >/dev/null 2>&1; then
    UI=dialog; MAUS=" (Maus)"
elif command -v whiptail >/dev/null 2>&1; then
    UI=whiptail; MAUS=""
else
    echo "Weder dialog noch whiptail vorhanden." >&2
    exit 1
fi
TITEL="BoatSpeedy — Kartendaten"

# ── Zustand ───────────────────────────────────────────────────────────────────

running()   { [ -n "$(docker ps --filter name=mapdata-build -q 2>/dev/null)" ]; }
regions()   { sed 's/#.*//' regions.txt | tr -d ' \t\r' | grep -v '^$'; }
gesamt()    { regions | wc -l; }
fertige()   { find "$GEO" -name '*.geojsonseq' 2>/dev/null | wc -l; }
aktuelles() { grep '^== europe/' "$LOG" 2>/dev/null | tail -1 | sed 's/^== //; s/ ==$//; s|europe/||'; }
schritt()   { grep -vE '^ (Container|Network|Image)|^#[0-9]|^ *$' "$LOG" 2>/dev/null | tail -1 | sed 's/^ *//'; }
human()     { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

lage() {
    local tiles=0 stand="—" frei
    if [ -f "$DATA/index.json" ]; then
        tiles=$(find "$DATA" -name '*.json.gz' | wc -l)
        stand=$(sed -n 's/.*"generated":"\([^"]*\)".*/\1/p' "$DATA/index.json")
    fi
    frei=$(df -h . | awk 'NR==2{print $4}')
    if running; then
        printf 'Läuft: %s von %s Gebieten — %s\n%s Kacheln ausgeliefert, Stand %s · %s frei' \
            "$(fertige)" "$(gesamt)" "$(aktuelles)" "$tiles" "$stand" "$frei"
    else
        printf 'Kein Vorgang aktiv\n%s Kacheln ausgeliefert, Stand %s · %s frei' \
            "$tiles" "$stand" "$frei"
    fi
}

msg()   { "$UI" --title "$TITEL" --msgbox "$1" "${2:-10}" 70; }
frage() { "$UI" --title "$TITEL" --yesno "$1" "${2:-12}" 70; }

# Reste eines abgebrochenen Downloads — aber nur, wenn gerade keiner lädt. Während eines
# Laufs ist eine .part-Datei kein Rest, sondern der Download selbst.
reste_weg() {
    running && return 0
    local n; n=$(find "$WORK" -maxdepth 1 -name '*.part' 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && return 0
    rm -f "$WORK"/*.part
    msg "$n abgebrochener Download wurde entfernt.\n\nSolche Reste entstehen, wenn ein Lauf mitten im Herunterladen endet. Eine halbe Datei darf nie als gültiger Auszug durchgehen — deshalb wird sie beim Start weggeräumt." 11
}

# ── Läufe ─────────────────────────────────────────────────────────────────────

starte() {
    if running; then
        msg "Es läuft bereits ein Vorgang.\n\nZwei gleichzeitig schreiben in dasselbe Arbeitsverzeichnis und zerlegen sich gegenseitig die Daten." 10
        return 1
    fi
    mkdir -p log "$WORK" "$DATA"
    [ -f "$LOG" ] && mv -f "$LOG" "$LOG.1"
    local mount=""
    [ -n "${1:-}" ] && mount="-v $(readlink -f "$1"):/build/regions.txt:ro"
    # shellcheck disable=SC2086
    setsid nohup sh -c "docker compose run --rm $mount mapdata-build > $LOG 2>&1" \
        </dev/null >/dev/null 2>&1 &
    sleep 6
    if running; then
        zusehen
    else
        msg "Der Vorgang ist nicht angesprungen.\n\n$(tail -5 "$LOG" 2>/dev/null)" 14
    fi
}

abbrechen() {
    running || { msg "Es läuft gerade nichts." 7; return; }
    frage "Laufenden Vorgang abbrechen?\n\nFertige Gebiete bleiben erhalten — ein neuer Lauf macht dort weiter, wo dieser stand. Ein angefangener Download wird verworfen und beim nächsten Mal neu geholt." 12 || return
    docker ps --filter name=mapdata-build -q | xargs -r docker rm -f >/dev/null 2>&1
    sleep 2
    rm -f "$WORK"/*.part
    msg "Abgebrochen.\n\n$(fertige) von $(gesamt) Gebieten sind fertig und bleiben es." 9
}

# ── Fortschritt ───────────────────────────────────────────────────────────────

zusehen() {
    local total; total=$(gesamt)
    local B=$'\033[1m' DIM=$'\033[2m' G=$'\033[32m' Y=$'\033[33m' N=$'\033[0m'
    while true; do
        clear 2>/dev/null || true
        local d c; d=$(fertige); c=$(aktuelles)
        if running; then
            printf '\n %sLäuft%s   %s\n\n' "$Y" "$N" \
                "$(docker ps --filter name=mapdata-build --format '{{.Status}}' | head -1)"
        else
            printf '\n %sKein Vorgang aktiv%s\n\n' "$G" "$N"
        fi
        local w=40 f i; f=$(( total > 0 ? d * w / total : 0 ))
        printf ' ['
        for ((i = 0; i < w; i++)); do
            if [ "$i" -lt "$f" ]; then printf '█'; else printf '░'; fi
        done
        printf ']  %s/%s' "$d" "$total"
        [ -n "$c" ] && printf '   %s%s%s' "$B" "$c" "$N"
        printf '\n\n'
        local r name mark col=0
        for r in $(regions); do
            name=$(printf '%s' "$r" | tr '/' '_')
            if [ -s "$GEO/$name.geojsonseq" ]; then mark="$G✓$N"
            elif [ "${r#europe/}" = "$c" ];     then mark="$Y▸$N"
            else                                     mark="$DIM·$N"
            fi
            printf '  %b %-16.16s' "$mark" "${r#europe/}"
            col=$((col + 1)); [ $((col % 4)) -eq 0 ] && printf '\n'
        done
        [ $((col % 4)) -ne 0 ] && printf '\n'
        printf '\n %s%s%s\n\n' "$DIM" "$(schritt)" "$N"
        printf ' %sTaste = zurück · a = abbrechen%s\n' "$DIM" "$N"
        local k=""
        if read -rsn1 -t 3 k; then
            if [ "$k" = a ]; then abbrechen; continue; fi
            return
        fi
    done
}

# ── Aktueller Lauf ────────────────────────────────────────────────────────────

# Was der Lauf gerade tut und was er bisher getan hat — als Seite zum Lesen.
#
# `zusehen` daneben ist der laufende Blick; das hier ist der Bericht. Er beantwortet die
# Frage, die vorher niemand beantworten konnte: Ist bei diesem Lauf ueberhaupt etwas
# Neues hereingekommen? Ein Lauf meldete "Fertig", obwohl die Aktualisierung
# fehlgeschlagen war und alles aus dem alten Auszug geschnitten wurde.
lauf_bericht() {
    local d c
    d=$(fertige); c=$(aktuelles)
    printf 'Stand dieser Ansicht: %s\n' "$(date '+%d.%m.%Y %H:%M:%S')"
    printf '%s\n' "-------------------------------------------------------------"
    if running; then
        printf 'Vorgang:   laeuft, %s\n' \
            "$(docker ps --filter name=mapdata-build --format '{{.Status}}' | head -1)"
        printf 'Gebiet:    %s   (%s von %s fertig)\n' "${c:-—}" "$d" "$(gesamt)"
        printf 'Schritt:   %s\n' "$(schritt)"
    else
        printf 'Vorgang:   keiner aktiv   (%s von %s Gebieten verarbeitet)\n' "$d" "$(gesamt)"
    fi
    printf '\n'

    # Was die Aktualisierung je Gebiet ergeben hat. Genau das fehlte: "Fertig" sagt
    # nichts darueber, ob neue Daten hereinkamen.
    printf 'Aktualisierung in diesem Lauf\n'
    printf '%s\n' "-------------------------------------------------------------"
    if [ -f "$LOG" ]; then
        awk '
            /^== europe\// { gebiet = $2; sub(/europe\//, "", gebiet); next }
            /^  Stand: / { sub(/^  Stand: /, ""); vorher[gebiet] = $0; next }
            /^  Aktualisierung: fertig, jetzt / {
                sub(/^  Aktualisierung: fertig, jetzt /, "")
                if ($0 == vorher[gebiet]) zustand[gebiet] = "unveraendert  " $0
                else                      zustand[gebiet] = "NEU           " $0
                if (!(gebiet in gesehen)) { gesehen[gebiet] = 1; reihe[++n] = gebiet }
                next
            }
            /^  Aktualisierung: FEHLGESCHLAGEN/ {
                zustand[gebiet] = "FEHLER        " vorher[gebiet]
                if (!(gebiet in gesehen)) { gesehen[gebiet] = 1; reihe[++n] = gebiet }
                next
            }
            /^  Grund: / { sub(/^  Grund: /, ""); grund[gebiet] = $0; next }
            END {
                if (n == 0) { print "  (noch nichts)"; exit }
                for (i = 1; i <= n; i++) {
                    g = reihe[i]
                    printf "  %-22.22s %s\n", g, zustand[g]
                    if (grund[g] != "") printf "  %-22.22s   %s\n", "", grund[g]
                }
            }' "$LOG"
    else
        printf '  (kein Protokoll)\n'
    fi
    printf '\n'
    printf 'Letzte Zeilen\n'
    printf '%s\n' "-------------------------------------------------------------"
    grep -vE '^ (Container|Network|Image)|^#[0-9]' "$LOG" 2>/dev/null | tail -12 | sed 's/^/  /'
}

lauf() {
    local f; f=$(mktemp)
    lauf_bericht > "$f"
    # --textbox statt --msgbox: msgbox bricht um wie Fliesstext und zerlegt dabei jede
    # Spaltenausrichtung.
    "$UI" --title "$TITEL — Aktueller Lauf" --textbox "$f" 24 78
    rm -f "$f"
    if running; then
        frage "Laufend mitverfolgen?\n\nDie Ansicht frischt sich alle drei Sekunden auf; jede Taste bringt dich zurueck." 10 && zusehen
    fi
}

# ── Aktionen ──────────────────────────────────────────────────────────────────

auffrischen() {
    frage "Auffrischen\n\nHolt für jedes Gebiet nur die Änderungen seit dem letzten Mal und baut die Kacheln neu. Der übliche Fall.\n\nDauer: gut eine Stunde, Download gering." 13 || return
    rm -rf "$GEO"
    starte ""
}

neuaufbau() {
    frage "Komplett neu aufbauen\n\nVerarbeitet jedes Gebiet von vorn — nötig, wenn sich am Filter oder am Kachelformat etwas geändert hat.\n\nDauert Stunden. Die Rohdaten bleiben, es wird also fast nichts heruntergeladen." 14 || return
    rm -rf "$GEO"
    starte ""
}

# Mehrfachauswahl statt eines einzelnen Landes: Wer nach einem Ausfall drei Gebiete
# nachholen will, soll nicht dreimal durch dasselbe Menü.
#
# Neben jedem Land steht sein Stand — sonst wählt man blind und weiß hinterher nicht,
# ob sich überhaupt etwas geändert hat.
laender() {
    local liste=() r name pbf stand
    for r in $(regions); do
        name=$(printf '%s' "$r" | tr '/' '_')
        pbf="$WORK/$name.osm.pbf"
        if [ -s "$pbf" ]; then
            stand="$(human "$(stat -c %s "$pbf")"), $(date -d "@$(stat -c %Y "$pbf")" '+%d.%m.' 2>/dev/null)"
        else
            stand="noch nicht geholt"
        fi
        # tag, beschreibung, vorauswahl
        liste+=("${r#europe/}" "$stand" off)
    done

    local wahl
    wahl=$("$UI" --title "$TITEL" --checklist \
        "Welche Gebiete auffrischen?\n\nLeertaste wählt aus, Tab zu den Knöpfen. Nur die Gewählten werden neu geholt und verarbeitet; die übrigen bleiben, wie sie sind." \
        22 72 12 "${liste[@]}" 3>&1 1>&2 2>&3) || return
    # whiptail gibt die Auswahl in Anführungszeichen zurück
    wahl=$(printf '%s' "$wahl" | tr -d '"')
    [ -z "$wahl" ] && return

    local anzahl=0
    : > /tmp/mapdata-auswahl.txt
    for g in $wahl; do
        rm -f "$GEO/europe_$g.geojsonseq"
        printf 'europe/%s\n' "$g" >> /tmp/mapdata-auswahl.txt
        anzahl=$((anzahl + 1))
    done

    frage "$anzahl Gebiete auffrischen?\n\n$(tr '\n' ' ' < /tmp/mapdata-auswahl.txt | sed 's|europe/||g')\n\nVorhandene Auszüge werden dabei nur aktualisiert, nicht neu geladen. Die Kacheln entstehen danach aus allen Gebieten neu." 14 || return
    starte /tmp/mapdata-auswahl.txt
}

gebiete() {
    # --textbox statt --msgbox: msgbox bricht den Inhalt um wie einen Fliesstext, und
    # dabei zerfaellt jede Spaltenausrichtung. textbox zeigt eine Datei woertlich.
    local f; f=$(mktemp)
    {
        printf '%-24s %9s %11s %7s\n' "Gebiet" "Rohdaten" "geholt am" "fertig"
        printf '%s\n' "-------------------------------------------------------"
        local r name pbf size datum zw
        for r in $(regions); do
            name=$(printf '%s' "$r" | tr '/' '_')
            pbf="$WORK/$name.osm.pbf"
            if [ -s "$pbf" ]; then
                size=$(human "$(stat -c %s "$pbf")")
                datum=$(date -d "@$(stat -c %Y "$pbf")" '+%d.%m.%Y' 2>/dev/null)
            else
                size="-"; datum="-"
            fi
            if [ -s "$GEO/$name.geojsonseq" ]; then zw="ja"; else zw="-"; fi
            printf '%-24s %9s %11s %7s\n' "${r#europe/}" "$size" "$datum" "$zw"
        done
        printf '\n%s\n' "Ohne Rohdaten wird neu geladen, mit Rohdaten nur die Änderungen."
        printf '%s\n' "\"fertig\" = verarbeitet; ein Lauf überspringt diese Gebiete."
    } > "$f"
    "$UI" --title "$TITEL — Gebiete" --textbox "$f" 24 62
    rm -f "$f"
}

# Der Auslieferer ist der nginx, der die Kacheln herausgibt. Geprueft wird zuerst;
# neu gestartet nur, wenn etwas nicht stimmt.
#
# Warum es das ueberhaupt braucht: Eine Docker-Einhaengung folgt dem Inode, nicht dem
# Pfad. Wird data/ geloescht und neu angelegt, zeigt der laufende Container weiter auf
# das alte, geloeschte Verzeichnis und liefert 404, obwohl die Dateien da sind. Genau
# das ist hier schon passiert.
pruefen() {
    local port a b
    port=$(grep -E '^MAPDATA_PORT=' .env 2>/dev/null | cut -d= -f2); port=${port:-8081}
    pruefe_codes() {
        a=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/mapdata/healthz" 2>/dev/null || echo '---')
        b=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/mapdata/index.json" 2>/dev/null || echo '---')
    }
    pruefe_codes
    if [ "$a$b" = "200200" ]; then
        msg "Auslieferer in Ordnung — kein Neustart nötig.\n\n  /mapdata/healthz      $a\n  /mapdata/index.json   $b" 11
        return
    fi
    frage "Auslieferer antwortet nicht richtig.\n\n  /mapdata/healthz      $a\n  /mapdata/index.json   $b\n\nNeu starten? Das hilft vor allem, wenn das Datenverzeichnis neu angelegt wurde — eine Einhängung folgt dem Inode, nicht dem Pfad." 14 || return
    docker compose up -d --force-recreate mapdata-web >/dev/null 2>&1
    sleep 3
    pruefe_codes
    if [ "$a$b" = "200200" ]; then
        msg "Neu gestartet — jetzt in Ordnung.\n\n  /mapdata/healthz      $a\n  /mapdata/index.json   $b" 11
    else
        msg "Auch nach dem Neustart nicht in Ordnung.\n\n  /mapdata/healthz      $a\n  /mapdata/index.json   $b\n\nProtokoll:  docker compose logs mapdata-web" 13
    fi
}

platz() {
    local geo pbf frei w
    geo=$(du -sh "$GEO" 2>/dev/null | cut -f1); geo=${geo:-0}
    pbf=$(du -ch "$WORK"/*.osm.pbf 2>/dev/null | tail -1 | cut -f1); pbf=${pbf:-0}
    frei=$(df -h . | awk 'NR==2{print $4}')
    w=$("$UI" --title "$TITEL" --menu "Platz freigeben — $frei frei" 14 72 3 \
        "1" "Zwischenergebnisse ($geo) — gefahrlos" \
        "2" "Rohdaten ($pbf) — kostet 28 GB Download" \
        "3" "Verwaiste Kacheln — Reste alter Läufe" \
        3>&1 1>&2 2>&3) || return
    case "$w" in
        1) frage "Zwischenergebnisse löschen?\n\nDer nächste Lauf erzeugt sie neu, ohne etwas herunterzuladen." 10 \
               && { rm -rf "$GEO"; msg "Gelöscht." 7; } ;;
        2) frage "Rohdaten wirklich löschen?\n\nDann lädt der nächste Lauf alle Auszüge neu — zusammen rund 28 GB von Geofabrik. Genau das hat schon einmal zu einer Sperre geführt." 12 \
               && { rm -f "$WORK"/*.osm.pbf; msg "Gelöscht." 7; } ;;
        3) verwaiste ;;
    esac
}

verwaiste() {
    [ -f "$DATA/index.json" ] || { msg "Kein Verzeichnis vorhanden." 7; return; }
    local n=0 f name
    for f in "$DATA"/*.json.gz; do
        [ -e "$f" ] || continue
        name=$(basename "$f" .json.gz)
        grep -q "\"$name\"" "$DATA/index.json" || { rm -f "$f"; n=$((n + 1)); }
    done
    msg "$n verwaiste Kacheln gelöscht." 7
}

# ── Hauptschleife ─────────────────────────────────────────────────────────────

reste_weg

while true; do
    if running; then
        wahl=$("$UI" --title "$TITEL$MAUS" --menu "$(lage)" 19 74 6 \
            "1" "Aktueller Lauf — was gerade passiert" \
            "2" "Zusehen — Fortschritt laufend" \
            "3" "Abbrechen — Vorgang stoppen" \
            "4" "Gebiete — Übersicht" \
            "5" "Auslieferer prüfen" \
            "6" "Platz freigeben" \
            3>&1 1>&2 2>&3) || break
        case "$wahl" in
            1) lauf ;; 2) zusehen ;; 3) abbrechen ;;
            4) gebiete ;; 5) pruefen ;; 6) platz ;;
        esac
    else
        wahl=$("$UI" --title "$TITEL$MAUS" --menu "$(lage)" 20 74 7 \
            "1" "Auffrischen — nur Änderungen holen" \
            "2" "Gebiete auffrischen — gezielt auswählen" \
            "3" "Neu aufbauen — alles, ohne Download" \
            "4" "Letzter Lauf — was dabei herauskam" \
            "5" "Gebiete — Übersicht" \
            "6" "Auslieferer prüfen" \
            "7" "Platz freigeben" \
            3>&1 1>&2 2>&3) || break
        case "$wahl" in
            1) auffrischen ;; 2) laender ;; 3) neuaufbau ;; 4) lauf ;;
            5) gebiete ;; 6) pruefen ;; 7) platz ;;
        esac
    fi
done

clear 2>/dev/null || true
