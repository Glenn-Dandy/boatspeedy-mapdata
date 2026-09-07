# Enthält nur, was zum Filtern und Schneiden gebraucht wird: osmium-tool für die
# OSM-Auszüge, Python für die Kacheln, curl zum Holen. Kein Dienst, kein Netzwerk-
# Zuhörer — der Container läuft einmal durch und beendet sich.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      osmium-tool \
      python3 \
      ca-certificates \
      curl \
 && rm -rf /var/lib/apt/lists/*

COPY build.sh tile.py /build/
RUN chmod +x /build/build.sh

WORKDIR /build
ENTRYPOINT ["/build/build.sh"]
