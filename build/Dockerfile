# Enthält nur, was zum Filtern und Schneiden gebraucht wird: osmium-tool für die
# OSM-Auszüge, pyosmium für die Änderungsströme, Python für die Kacheln, curl zum Holen. Kein Dienst, kein Netzwerk-
# Zuhörer — der Container läuft einmal durch und beendet sich.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      osmium-tool \
      python3 \
      pyosmium \
      ca-certificates \
      curl \
 && rm -rf /var/lib/apt/lists/*

# Die Skripte kommen zur Laufzeit als Einhängepunkt dazu (siehe docker-compose.yml).
# Sie hier hineinzukopieren hieße, das Abbild nach jeder Änderung neu bauen zu müssen —
# und wer das vergisst, lässt unbemerkt die alte Fassung laufen.
WORKDIR /build
ENTRYPOINT ["sh", "/build/build.sh"]
