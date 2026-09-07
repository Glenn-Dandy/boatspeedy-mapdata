#!/usr/bin/env python3
"""
Macht aus dem GeoJSON-Strom von osmium die Kacheln, die die App lädt.

Eine Kachel ist ein Grad breit und ein Grad hoch — am Boden etwa 110 x 70 km in
unseren Breiten. Der Zuschnitt ist bewusst grob: Bei dieser Größe lädt ein Boot mit
einem Umkreis von 150 km rund zehn Dateien, und jede einzelne bleibt klein genug,
um über Mobilfunk zu gehen.

Das Ausgabeformat entspricht dem, was die App ohnehin von Overpass bekommt
(`elements` mit `type`, `tags`, `geometry`). Damit liest sie die Kacheln mit
demselben Code — die Datenquelle wechselt, die Auswertung bleibt.
"""

from __future__ import annotations

import gzip
import json
import math
import os
import sys
from collections import defaultdict

# Nur diese Merkmale werden gebraucht — der Rest ist Ballast. Ohne diese Beschränkung
# wächst eine Kachel um ein Vielfaches, ohne dass die App irgendetwas davon liest.
KEEP_WAY = (
    "waterway", "name",
    "boat", "motorboat", "ship", "canoe", "access", "tunnel",
)
KEEP_NODE = (
    "waterway", "barrier", "name",
    "seamark:notice:category", "seamark:notice:information",
    "seamark:notice:impact", "seamark:notice:function",
    "waterway:maxspeed", "maxspeed",
)

# Fünf Nachkommastellen sind gut ein Meter. Feiner brauchen wir es nicht, und jede
# weitere Stelle kostet über alle Stützpunkte hinweg spürbar Platz.
PLACES = 5


def tile_name(lat: int, lon: int) -> str:
    """Kachelname nach Südwestecke, etwa `n50e011` — wie bei Höhendaten üblich."""
    ns = "n" if lat >= 0 else "s"
    ew = "e" if lon >= 0 else "w"
    return f"{ns}{abs(lat):02d}{ew}{abs(lon):03d}"


def tile_of(lat: float, lon: float) -> tuple[int, int]:
    return math.floor(lat), math.floor(lon)


def load(path: str, buckets: dict, seen: set) -> tuple[int, int]:
    """Liest eine GeoJSON-Zeilendatei und verteilt die Objekte auf Kacheln."""
    kept = skipped = 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip().lstrip("\x1e")  # RS-Trenner, falls vorhanden
            if not line:
                continue
            try:
                feat = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue

            props = feat.get("properties") or {}
            geom = feat.get("geometry") or {}
            gtype = geom.get("type")
            coords = geom.get("coordinates")
            if not coords:
                skipped += 1
                continue

            # Grenzflüsse stehen in beiden Länderauszügen. Ohne diese Prüfung läge
            # die Elbe an der tschechischen Grenze doppelt in derselben Kachel.
            oid = props.pop("@id", None)
            if oid is not None:
                if oid in seen:
                    continue
                seen.add(oid)

            if gtype == "LineString":
                tags = {k: v for k, v in props.items() if k in KEEP_WAY}
                if not tags.get("waterway"):
                    skipped += 1
                    continue
                # GeoJSON zählt Länge vor Breite — hier andersherum, wie bei Overpass.
                pts = [
                    {"lat": round(c[1], PLACES), "lon": round(c[0], PLACES)}
                    for c in coords
                ]
                if len(pts) < 2:
                    skipped += 1
                    continue
                element = {"type": "way", "tags": tags, "geometry": pts}
                # In jede Kachel, die der Weg berührt. Ein Fluss, der über eine Kante
                # läuft, liegt damit vollständig in beiden — etwas Doppelung, dafür
                # passt das Netz beim Zusammensetzen lückenlos zusammen.
                for t in {tile_of(p["lat"], p["lon"]) for p in pts}:
                    buckets[t].append(element)
                kept += 1

            elif gtype == "Point":
                tags = {k: v for k, v in props.items() if k in KEEP_NODE}
                if not tags:
                    skipped += 1
                    continue
                lat = round(coords[1], PLACES)
                lon = round(coords[0], PLACES)
                element = {"type": "node", "tags": tags, "lat": lat, "lon": lon}
                buckets[tile_of(lat, lon)].append(element)
                kept += 1

            else:
                skipped += 1
    return kept, skipped


def write(buckets: dict, out_dir: str, generated: str) -> dict:
    os.makedirs(out_dir, exist_ok=True)
    index = {}
    for (lat, lon), elements in sorted(buckets.items()):
        name = tile_name(lat, lon)
        payload = {
            "version": 1,
            "tile": name,
            "generated": generated,
            "elements": elements,
        }
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
        path = os.path.join(out_dir, f"{name}.json.gz")
        # mtime=0, damit zwei Läufe mit gleichem Inhalt gleiche Dateien ergeben —
        # sonst sieht jeder Lauf nach Änderung aus, obwohl sich nichts geändert hat.
        with gzip.GzipFile(path, "wb", compresslevel=9, mtime=0) as fh:
            fh.write(raw)
        index[name] = {
            "bytes": os.path.getsize(path),
            "elements": len(elements),
        }
    return index


def main() -> int:
    if len(sys.argv) < 4:
        print("Aufruf: tile.py <ausgabe-verzeichnis> <datum> <geojsonseq...>", file=sys.stderr)
        return 2
    out_dir, generated, inputs = sys.argv[1], sys.argv[2], sys.argv[3:]

    buckets: dict[tuple[int, int], list] = defaultdict(list)
    seen: set = set()
    total_kept = total_skipped = 0
    for path in inputs:
        kept, skipped = load(path, buckets, seen)
        total_kept += kept
        total_skipped += skipped
        print(f"  {os.path.basename(path)}: {kept} übernommen, {skipped} übergangen")

    index = write(buckets, out_dir, generated)
    total_bytes = sum(v["bytes"] for v in index.values())

    with open(os.path.join(out_dir, "index.json"), "w", encoding="utf-8") as fh:
        json.dump(
            {
                "version": 1,
                "generated": generated,
                "attribution": "© OpenStreetMap-Mitwirkende, ODbL 1.0 — über Geofabrik",
                "tiles": index,
            },
            fh,
            separators=(",", ":"),
            ensure_ascii=False,
        )

    print(f"\n{len(index)} Kacheln, {total_kept} Objekte, {total_bytes / 1048576:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
