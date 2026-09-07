#!/bin/sh
# Zeigt, wo der Erzeugungslauf gerade steht.
#
# Ohne das muss man sich die Antwort aus drei Befehlen zusammensuchen: läuft der
# Container noch, wie groß sind die Zwischendateien, wie viele Kacheln liegen schon da.
#
# Aufruf:  ./status.sh          einmalig
#          ./status.sh -f       fortlaufend, wie tail -f
set -eu

cd "$(dirname "$0")"

LOG=log/build.log
[ -f "$LOG" ] || LOG=/tmp/mapbuild.log

if [ "${1:-}" = "-f" ]; then
    [ -f "$LOG" ] || { echo "Kein Protokoll gefunden."; exit 1; }
    exec tail -f "$LOG"
fi

printf '== Lauf ==\n'
if docker ps --filter name=mapdata-build --format '{{.Status}}' | grep -q .; then
    printf '  läuft seit %s\n' "$(docker ps --filter name=mapdata-build --format '{{.Status}}' | head -1)"
else
    printf '  kein Lauf aktiv\n'
fi

printf '\n== Schritt ==\n'
if [ -f "$LOG" ]; then
    # Die letzte Zeile, die kein Docker-Geplapper ist.
    grep -vE '^ (Container|Network|Image)' "$LOG" | tail -3 | sed 's/^/  /'
else
    printf '  kein Protokoll\n'
fi

printf '\n== Zwischenstand ==\n'
if [ -d build/work ] && [ -n "$(ls -A build/work 2>/dev/null)" ]; then
    du -sh build/work/* 2>/dev/null | sed 's/^/  /'
else
    printf '  nichts in Arbeit\n'
fi

printf '\n== Kacheln ==\n'
if [ -f data/index.json ]; then
    n=$(find data -name '*.json.gz' | wc -l)
    printf '  %s Stück, %s, Stand %s\n' \
        "$n" \
        "$(du -sh data | cut -f1)" \
        "$(sed -n 's/.*"generated":"\([^"]*\)".*/\1/p' data/index.json)"
else
    n=$(find data -name '*.json.gz' 2>/dev/null | wc -l)
    printf '  %s fertig, Verzeichnis noch nicht geschrieben\n' "$n"
fi

printf '\n== Platte ==\n'
df -h . | tail -1 | sed 's/^/  /'
