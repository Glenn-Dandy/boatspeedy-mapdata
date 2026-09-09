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

**In zwei Durchgängen, und das ist wesentlich.** Ein erster Versuch hielt alle Objekte
im Speicher, bis alles gelesen war; bei Deutschland wurde der Vorgang dabei vom
Betriebssystem abgeräumt. Jetzt wandert jedes Objekt sofort in eine Zwischendatei je
Kachel, und erst danach wird Kachel für Kachel gepackt — im Speicher liegt immer nur
eine.
"""

from __future__ import annotations

import glob
import gzip
import json
import math
import os
import re
import sys
from collections import OrderedDict

# Nur diese Merkmale werden gebraucht — der Rest ist Ballast. Ohne diese Beschränkung
# wächst eine Kachel um ein Vielfaches, ohne dass die App irgendetwas davon liest.
KEEP_WAY = (
    "waterway", "name",
    "boat", "motorboat", "ship", "canoe", "access", "tunnel",
    # Schleusen. Sie stehen in OSM als Weg — die Kammer als `waterway=canal` mit
    # `lock=yes`, die Tore als kurze Wege mit `waterway=lock_gate`. Ohne diese Merkmale
    # lag die Schleuse Wettin zwar in der Kachel, aber als namenloser 111-Meter-Kanal:
    # keine Öffnungszeiten, keine Nummer, und im Routing tauchte sie gar nicht auf.
    "lock", "lock_name", "opening_hours", "phone", "vhf",
    "maxlength", "maxwidth", "CEMT", "ref",
)
KEEP_NODE = (
    "waterway", "barrier", "name",
    "waterway:maxspeed", "maxspeed",
)

# Bei Seezeichen wird **alles** behalten, was mit `seamark:` beginnt.
#
# Eine feste Liste war hier falsch: Sie enthielt die Hinweistafeln, aber nicht
# `seamark:type` — womit jedes Zeichen seine Kennung verlor und stillschweigend
# wegfiel. In den Kacheln standen null Seezeichen, obwohl allein für Deutschland
# 90.963 im Zwischenergebnis lagen. Welche Merkmale ein Zeichen trägt, hängt von
# seiner Art ab (Tonne, Bake, Feuer, Sperrgebiet); eine Liste davon zu pflegen
# hieße, sie immer wieder unvollständig zu haben.
SEAMARK_PREFIX = "seamark:"

# Fünf Nachkommastellen sind gut ein Meter. Feiner brauchen wir es nicht, und jede
# weitere Stelle kostet über alle Stützpunkte hinweg spürbar Platz.
PLACES = 5

# So viele Zwischendateien bleiben gleichzeitig offen. Europa hat rund 800 Kacheln,
# die Voreinstellung für offene Dateien liegt bei 1024 — ohne Deckel liefe das knapp
# am Limit entlang.
MAX_OPEN = 96


def tile_name(lat: int, lon: int) -> str:
    """Kachelname nach Südwestecke, etwa `n50e011` — wie bei Höhendaten üblich."""
    ns = "n" if lat >= 0 else "s"
    ew = "e" if lon >= 0 else "w"
    return f"{ns}{abs(lat):02d}{ew}{abs(lon):03d}"


class Buckets:
    """Schreibt Objekte in Zwischendateien je Kachel und hält dabei wenige offen."""

    def __init__(self, work_dir: str):
        self.dir = work_dir
        os.makedirs(work_dir, exist_ok=True)
        self.open: OrderedDict[str, object] = OrderedDict()
        self.names: set[str] = set()

    def _handle(self, name: str):
        fh = self.open.get(name)
        if fh is not None:
            self.open.move_to_end(name)
            return fh
        if len(self.open) >= MAX_OPEN:
            _, victim = self.open.popitem(last=False)
            victim.close()
        # Anhängen, nicht überschreiben: dieselbe Kachel wird über mehrere Gebiete
        # hinweg immer wieder geöffnet und geschlossen.
        fh = open(os.path.join(self.dir, f"{name}.jsonl"), "a", encoding="utf-8")
        self.open[name] = fh
        self.names.add(name)
        return fh

    def add(self, name: str, line: str) -> None:
        self._handle(name).write(line + "\n")

    def close(self) -> None:
        for fh in self.open.values():
            fh.close()
        self.open.clear()


def collect(path: str, buckets: Buckets) -> tuple[int, int]:
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

            # Die Kennung bleibt vorerst dabei: Grenzflüsse stehen in beiden
            # Länderauszügen und werden erst beim Packen entdoppelt — dort ist die
            # Menge klein genug, um sie im Speicher zu halten.
            oid = props.pop("@id", None)

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
                if oid is not None:
                    element["i"] = oid
                out = json.dumps(element, separators=(",", ":"), ensure_ascii=False)
                # In jede Kachel, die der Weg berührt. Ein Fluss, der über eine Kante
                # läuft, liegt damit vollständig in beiden — etwas Doppelung, dafür
                # passt das Netz beim Zusammensetzen lückenlos zusammen.
                tiles = {
                    (math.floor(p["lat"]), math.floor(p["lon"])) for p in pts
                }
                for lat, lon in tiles:
                    buckets.add(tile_name(lat, lon), out)
                kept += 1

            elif gtype == "Point":
                tags = {
                    k: v for k, v in props.items()
                    if k in KEEP_NODE or k.startswith(SEAMARK_PREFIX)
                }
                if not tags:
                    skipped += 1
                    continue
                lat = round(coords[1], PLACES)
                lon = round(coords[0], PLACES)
                element = {"type": "node", "tags": tags, "lat": lat, "lon": lon}
                if oid is not None:
                    element["i"] = oid
                buckets.add(
                    tile_name(math.floor(lat), math.floor(lon)),
                    json.dumps(element, separators=(",", ":"), ensure_ascii=False),
                )
                kept += 1

            else:
                skipped += 1
    return kept, skipped


def kopfdatum(path: str) -> str | None:
    """Nur das Datum vorn aus einer Kachel — die Objekte dahinter sind Megabyte."""
    try:
        with gzip.open(path, "rb") as fh:
            kopf = fh.read(200).decode("utf-8", "ignore")
    except OSError:
        return None
    treffer = re.search(r'"generated":"([^"]+)"', kopf)
    return treffer.group(1) if treffer else None


def vorhanden(path: str) -> tuple[list, str | None]:
    """Objekte und Datum einer schon ausgelieferten Kachel — für den Vergleich."""
    try:
        with gzip.open(path, "rb") as fh:
            alt = json.loads(fh.read().decode("utf-8"))
    except (OSError, ValueError):
        return [], None
    return alt.get("elements") or [], alt.get("generated")


def gleich(a: list, b: list) -> bool:
    """Ob zwei Objektlisten dasselbe enthalten — ohne Rücksicht auf die Reihenfolge.

    Die Reihenfolge hängt daran, in welcher Folge die Länderdateien gelesen wurden. Wird
    ein einzelnes Gebiet neu verarbeitet, kann sie sich verschieben, ohne dass sich etwas
    geändert hätte. Verglichen wird deshalb, **was** drinsteht, nicht in welcher Ordnung.
    """
    if len(a) != len(b):
        return False
    schluessel = lambda el: json.dumps(el, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return sorted(map(schluessel, a)) == sorted(map(schluessel, b))


def pack(buckets: Buckets, out_dir: str, generated: str) -> dict:
    """Packt jede Kachel für sich — es liegt immer nur eine im Speicher."""
    os.makedirs(out_dir, exist_ok=True)
    for leftover in glob.glob(os.path.join(out_dir, "*.json.gz.tmp")):
        os.remove(leftover)
    index = {}
    unveraendert = 0
    for name in sorted(buckets.names):
        src = os.path.join(buckets.dir, f"{name}.jsonl")
        elements = []
        seen: set = set()
        with open(src, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                el = json.loads(line)
                oid = el.pop("i", None)
                if oid is not None:
                    if oid in seen:
                        continue
                    seen.add(oid)
                elements.append(el)
        if not elements:
            continue

        path = os.path.join(out_dir, f"{name}.json.gz")

        # **Unveränderte Kacheln behalten ihr Datum.**
        #
        # Ein Lauf über ein einzelnes Land schneidet trotzdem alle Kacheln neu — anders
        # ginge es nicht, ein Fluss läuft über die Grenze und die Kachel braucht beide
        # Seiten. Wurde dabei jeder Kachel das Lauf-Datum aufgestempelt, hielt die App
        # anschließend **alles** für veraltet: Nach einem Deutschland-Lauf wollte sie auch
        # die portugiesischen Kacheln neu laden, in denen sich seit Monaten nichts geändert
        # hat. In einem Umkreis von 150 km sind das rund 3,4 MB, von denen eine einzige
        # Kachel wirklich neu ist.
        alte, altes_datum = vorhanden(path)
        if altes_datum and gleich(alte, elements):
            index[name] = {
                "bytes": os.path.getsize(path),
                "elements": len(alte),
                "generated": altes_datum,
            }
            os.remove(src)
            unveraendert += 1
            continue

        payload = {
            "version": 1,
            "tile": name,
            "generated": generated,
            "elements": elements,
        }
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
        tmp = f"{path}.tmp"
        # mtime=0, damit zwei Läufe mit gleichem Inhalt gleiche Dateien ergeben —
        # sonst sieht jeder Lauf nach Änderung aus, obwohl sich nichts geändert hat.
        with gzip.GzipFile(tmp, "wb", compresslevel=9, mtime=0) as fh:
            fh.write(raw)
        # Erst schreiben, dann umbenennen. Der Auslieferer bedient währenddessen weiter
        # aus demselben Verzeichnis; an Ort und Stelle geschrieben bekäme jemand, der
        # genau in diesem Augenblick fragt, ein halbes Stück. Das Umbenennen innerhalb
        # eines Dateisystems ist unteilbar — man sieht entweder die alte Kachel oder die
        # neue, nie etwas dazwischen.
        os.replace(tmp, path)
        index[name] = {
            "bytes": os.path.getsize(path),
            "elements": len(elements),
            "generated": generated,
        }
        os.remove(src)
    if unveraendert:
        print(f"  {unveraendert} Kacheln unverändert, Datum behalten", flush=True)
    return index


def main() -> int:
    if len(sys.argv) < 5:
        print(
            "Aufruf: tile.py <ausgabe> <arbeitsverzeichnis> <datum> <geojsonseq...>",
            file=sys.stderr,
        )
        return 2
    out_dir, work_dir, generated, inputs = (
        sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    )

    buckets = Buckets(work_dir)
    total_kept = total_skipped = 0
    for path in inputs:
        kept, skipped = collect(path, buckets)
        total_kept += kept
        total_skipped += skipped
        print(f"  {os.path.basename(path)}: {kept} übernommen, {skipped} übergangen", flush=True)
    buckets.close()

    index = pack(buckets, out_dir, generated)

    # Das vorhandene Verzeichnis wird **ergaenzt**, nicht ersetzt.
    #
    # Ein Lauf ueber ein einzelnes Land schrieb sonst ein Verzeichnis mit neun Kacheln,
    # waehrend 1373 auf der Platte lagen und weiter ausgeliefert wurden. Die Dateien
    # waren unversehrt, aber das Verzeichnis log - und die App liest daraus, was es gibt
    # und was ein Download kostet.
    #
    # Umgekehrt fliegen Eintraege raus, deren Datei nicht mehr da ist; sonst wuerde das
    # Verzeichnis Kacheln versprechen, die niemand mehr ausliefern kann.
    index_path = os.path.join(out_dir, "index.json")
    merged = {}
    if os.path.isfile(index_path):
        try:
            with open(index_path, encoding="utf-8") as fh:
                merged = json.load(fh).get("tiles", {})
        except (OSError, ValueError):
            merged = {}
    merged.update(index)
    merged = {
        k: v for k, v in merged.items()
        if os.path.isfile(os.path.join(out_dir, f"{k}.json.gz"))
    }
    # Eintraege aus einem aelteren Verzeichnis tragen noch kein eigenes Datum. Es steht in
    # der Kachel selbst - von dort wird es einmalig nachgetragen, damit die App auch die
    # nicht angefassten Gebiete je Kachel vergleichen kann.
    for name, eintrag in merged.items():
        if not eintrag.get("generated"):
            eintrag["generated"] = kopfdatum(os.path.join(out_dir, f"{name}.json.gz")) or generated
    index = dict(sorted(merged.items()))
    total_bytes = sum(v["bytes"] for v in index.values())

    with open(index_path, "w", encoding="utf-8") as fh:
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

    print(f"\n{len(index)} Kacheln im Verzeichnis, {total_kept} Objekte verarbeitet, "
          f"{total_bytes / 1048576:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
