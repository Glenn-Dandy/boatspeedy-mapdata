#!/bin/sh
# Erzeugt die Kacheln neu und startet den Auslieferer durch.
#
# Aufruf:  ./update.sh
# Für den Cron-Eintrag gedacht — monatlich reicht. Wasserwege ändern sich in Monaten
# kaum, und jeder Lauf lädt mehrere Gigabyte von Geofabrik.
set -eu

cd "$(dirname "$0")"

echo "== Quellen holen =="
git pull --ff-only

echo "== Erzeuger bauen =="
docker compose build --pull mapdata-build

echo "== Kacheln erzeugen =="
# Ins Protokoll **und** auf den Bildschirm: So kann ./status.sh später nachsehen,
# wie weit ein Lauf gekommen ist, auch wenn niemand zugesehen hat.
mkdir -p log
docker compose run --rm mapdata-build 2>&1 | tee log/build.log

echo "== Auslieferer starten =="
docker compose up -d mapdata-web

echo "== Aufräumen =="
docker image prune -f >/dev/null
rm -rf build/work

port=$(grep -E '^MAPDATA_PORT=' .env 2>/dev/null | cut -d= -f2)
port=${port:-8081}

echo "== Prüfen =="
sleep 2
printf "  /healthz     %s\n" "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz" || echo '---')"
printf "  /index.json  %s\n" "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/index.json" || echo '---')"
echo
du -sh data 2>/dev/null | sed 's/^/  Umfang: /'
