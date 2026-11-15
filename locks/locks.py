#!/usr/bin/env python3
"""Holt die Betriebszeiten der Schleusen von ELWIS und legt sie als JSON ab.

ELWIS hat dafür keine Schnittstelle, aber je Schleuse eine Seite mit einer festen Tabelle:
Zeitraum, dann Montag bis Sonntag. Die Seiten werden einzeln abgerufen, mit einer Pause
dazwischen, und die Tabelle **unverändert** übernommen. So verlangen es die
Nutzungsbedingungen von ELWIS (Open Data, Quelle www.elwis.de, Inhalt unverändert).

Die Seiten nennen keine Koordinaten, nur Name und Wasserstraße. Die Lage kommt aus den
eigenen Kacheln: Eine ELWIS-Schleuse bekommt die Stelle der OSM-Schleuse mit demselben
Namen. Gibt es den Namen mehrfach, entscheidet die Wasserstraße; bleibt es mehrdeutig,
fällt die Schleuse weg. Lieber keine Zeiten als die einer anderen Schleuse.

Aufruf: locks.py <ausgabeverzeichnis> [--once]
"""
import datetime as dt
import glob
import gzip
import html
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

BASE = "https://www.elwis.de/DE/dynamisch/Schleuseninformationen/"
USER_AGENT = "boatspeedy-mapdata (+https://github.com/Glenn-Dandy/boatspeedy-mapdata)"

# Einmal am Tag. Die Zeiten ändern sich ein paarmal im Jahr, und ein Lauf sind über
# 500 Seiten.
INTERVAL_S = 24 * 3600

# Pause zwischen zwei Seiten. ELWIS braucht selbst oft mehrere Sekunden für eine Seite,
# ein Lauf dauert knapp eine Stunde. Eilig ist es nicht, die Zeiten gelten monatelang.
PAUSE_S = 1.0

# Nur Kacheln in diesem Rahmen werden nach Schleusen durchsucht: ELWIS kennt nur
# Bundeswasserstraßen, und Europa ganz zu lesen kostet unnötig Zeit.
RAHMEN = (47, 55, 5, 15)  # Süd, Nord, West, Ost in ganzen Grad

# Mehr Punkte je Schleuse braucht niemand, um sie zu treffen.
MAX_PUNKTE = 12

WOCHENTAGE = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]


# ------------------------------------------------------------------ Abruf

class Elwis:
    """Die Liste braucht ein Formular samt Sitzung, die Seiten je Schleuse nicht."""

    def __init__(self):
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def get(self, url: str) -> str:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with self.opener.open(req, timeout=60) as r:
            return r.read().decode("utf-8", errors="replace")

    def liste(self) -> str:
        start = self.get(BASE + "suche_start")
        m = re.search(r'name="form\[_token\]" value="([^"]*)"', start)
        if not m:
            raise RuntimeError("Suchformular ohne Token, hat ELWIS die Seite umgebaut?")
        q = urllib.parse.urlencode({
            "form[sluice]": "", "form[jsEnabled]": "0", "form[_token]": m.group(1),
            "cmd_choice": "Auswählen",
        })
        return self.get(BASE + "suche?" + q)

    def seite(self, ident: str) -> str:
        return self.get(BASE + "anzeigen?schleusenid=" + ident)


def text(s: str) -> str:
    """HTML-Stück zu Text: Zeilenumbrüche bleiben, sonst ein Leerzeichen."""
    s = re.sub(r"<br\s*/?>", "\n", s)
    s = html.unescape(re.sub(r"<[^>]+>", " ", s))
    zeilen = [re.sub(r"[ \t\xa0]+", " ", z).strip() for z in s.split("\n")]
    return "\n".join(z for z in zeilen if z)


def schleusen(liste: str) -> list[dict]:
    """Alle Schleusen der Liste mit ihrer Wasserstraße, in der Reihenfolge von ELWIS."""
    out = []
    wasserstrasse = None
    for m in re.finditer(
        r'<noscript>([^<]+)</noscript>|name="SchleusenIds\[\]"[^>]*value="(\d+)"\s*/>\s*([^<]+?)\s*</td>',
        liste,
    ):
        if m.group(1):
            wasserstrasse = html.unescape(m.group(1)).strip()
        else:
            out.append({"id": m.group(2), "name": html.unescape(m.group(3)).strip(),
                        "fairway": wasserstrasse})
    return out


def zeiten(seite: str) -> dict | None:
    """Die Tabelle der Betriebszeiten, Zelle für Zelle so, wie ELWIS sie zeigt."""
    # Die Klasse tragen auf der Seite mehrere Tabellen, auch die der Meldungen. Gemeint
    # ist die erste nach der Überschrift.
    # Manche Schleusen haben keine („Für diese Schleuse wurden keine Betriebszeiten
    # eingetragen"); dann käme als Nächstes schon die Tabelle der Feiertage.
    h = seite.find("<h2>Betriebszeiten der Schleuse")
    if h < 0:
        return None
    ende = seite.find("Feiertage", h)
    i = seite.find('class="schleusenzeit"', h, ende if ende > 0 else len(seite))
    if i < 0:
        return None
    tabelle = seite[i:seite.find("</table>", i)]
    zeilen = re.findall(r"<tr>(.*?)</tr>", tabelle, re.S)
    if not zeilen:
        return None
    kopf = [text(c) for c in re.findall(r"<th[^>]*>(.*?)</th>", zeilen[0], re.S)]
    if kopf[1:] != WOCHENTAGE:
        raise RuntimeError(f"Unbekannter Tabellenkopf: {kopf}")
    rows = []
    for z in zeilen[1:]:
        zellen = [text(c) for c in re.findall(r"<td[^>]*>(.*?)</td>", z, re.S)]
        if len(zellen) == 8 and "<th" not in z:
            rows.append({"period": zellen[0], "days": zellen[1:]})
    out = {"rows": rows}
    # Bemerkungen stehen als letzte Zeile in derselben Tabelle.
    m = re.search(r"Bemerkungen\s*</th>\s*</tr>\s*<tr>\s*<td[^>]*>(.*?)</td>", tabelle, re.S)
    if m and text(m.group(1)):
        out["remarks"] = text(m.group(1))
    return out


# ------------------------------------------------------------------ Lage aus OSM

# Wörter, die nur die Kammer oder die Art bezeichnen. Übrig bleibt der Ort, und der ist
# bei ELWIS und in OSM derselbe: "Mühlendamm Nordkammer" und "Schleuse Mühlendamm".
FUELLWOERTER = {
    "alt", "alte", "alter", "neu", "neue", "neuer", "nord", "süd", "ost", "west",
    "grosse", "kleine", "gross", "klein", "mittlere", "linke", "rechte", "obere", "untere",
    "unterer", "oberer", "kammer", "nordkammer", "südkammer", "ostkammer", "westkammer",
    "mittelkammer", "nordschleuse", "südschleuse", "ostschleuse", "westschleuse",
    "grossschleuse", "kleinschleuse", "schleuse", "doppelschleuse", "sparschleuse",
    "doppelsparschleuse", "schleusenanlage", "schiffsschleuse", "bootsschleuse",
    "sportbootschleuse", "sportboot", "bootstreppe", "bootsgasse", "hebewerk",
    "schiffshebewerk", "kahnschleuse", "kammerschleuse", "bootssschleuse", "trog", "i",
    "ii", "iii", "an", "der", "am", "bei",
}


def kerne(name: str) -> list[str]:
    """ "Mühlendamm Nordkammer" und "Schleuse Mühlendamm" -> ["mühlendamm"].

    Mit Schrägstrich sind es zwei Namen für dieselbe Stelle, etwa "Henrichenburg /
    Waltrop"; dann zählt jeder für sich.
    """
    s = name.lower().replace("ß", "ss")
    s = re.sub(r"\([^)]*\)", " ", s)
    out = []
    for teil in s.split("/"):
        woerter = [w for w in re.split(r"[\s\-,.]+", teil)
                   if w and w not in FUELLWOERTER and not re.fullmatch(r"(?:trog)?\d+", w)]
        if woerter:
            out.append(" ".join(woerter))
    return out


def wort(name: str | None) -> str:
    return re.sub(r"[^a-zäöü]", "", (name or "").lower().replace("ß", "ss"))


def mitte(e: dict) -> tuple[float, float] | None:
    if e.get("type") == "node" and "lat" in e:
        return e["lat"], e["lon"]
    g = e.get("geometry") or []
    if not g:
        return None
    return (sum(p["lat"] for p in g) / len(g), sum(p["lon"] for p in g) / len(g))


def osm_schleusen(out_dir: str) -> dict[str, list[dict]]:
    """Schleusen aus den Kacheln, nach Namenskern: Lage und Name des Gewässers."""
    s, n, w, o = RAHMEN
    out: dict[str, list[dict]] = {}
    for pfad in sorted(glob.glob(os.path.join(out_dir, "n*e*.json.gz"))):
        m = re.fullmatch(r"n(\d+)e(\d+)\.json\.gz", os.path.basename(pfad))
        if not m or not (s <= int(m[1]) < n and w <= int(m[2]) < o):
            continue
        with gzip.open(pfad) as f:
            elemente = json.load(f).get("elements", [])
        for e in elemente:
            t = e.get("tags") or {}
            schleuse = (t.get("lock") == "yes" or t.get("waterway") in ("lock_gate", "boat_lift")
                        or t.get("seamark:type") in ("lock_basin", "lock_basin_part"))
            if not schleuse:
                continue
            namen = {t.get("lock_name"), t.get("lock:name"), t.get("seamark:name")}
            # `name` ist an der Kammer oft der Kanal. Als Schleusenname nur, wenn es
            # danach klingt.
            if t.get("name") and ("schleuse" in t["name"].lower() or "lock_name" not in t):
                namen.add(t.get("name"))
            lage = mitte(e)
            if not lage:
                continue
            gewaesser = t.get("name") if t.get("lock_name") else None
            for nm in filter(None, namen):
                for k in kerne(nm):
                    out.setdefault(k, []).append({"lat": lage[0], "lon": lage[1], "fairway": gewaesser})
    return out


def entfernt_m(a: dict, b: dict) -> float:
    import math
    dy = (a["lat"] - b["lat"]) * 111_320
    dx = (a["lon"] - b["lon"]) * 111_320 * math.cos(math.radians(a["lat"]))
    return math.hypot(dx, dy)


def orte(treffer: list[dict]) -> list[list[dict]]:
    """Treffer in Gruppen, die beieinander liegen: eine Schleuse mit ihren Kammern und Toren."""
    gruppen: list[list[dict]] = []
    for t in treffer:
        for g in gruppen:
            if entfernt_m(g[0], t) < 1500:
                g.append(t)
                break
        else:
            gruppen.append([t])
    return gruppen


def verorten(schleuse: dict, osm: dict[str, list[dict]]) -> list[list[float]] | None:
    """Die Punkte der passenden OSM-Schleuse: Kammern und Tore, jeder für sich.

    Ein Mittelwert wäre bequemer, liegt aber bei Doppelschleusen wie Hameln weit neben
    jeder Kammer. Die App sucht den nächsten Punkt.
    """
    gruppen = orte([t for k in kerne(schleuse["name"]) for t in osm.get(k, [])])
    if len(gruppen) > 1:
        # Den Namen gibt es öfter. Die Wasserstraße entscheidet, wenn OSM sie nennt.
        fw = wort(schleuse.get("fairway"))
        passend = [g for g in gruppen if fw and any(
            x["fairway"] and (wort(x["fairway"]) in fw or fw in wort(x["fairway"])) for x in g)]
        gruppen = passend
    if len(gruppen) != 1:
        return None
    punkte = {(round(x["lat"], 5), round(x["lon"], 5)) for x in gruppen[0]}
    return [list(p) for p in sorted(punkte)][:MAX_PUNKTE]


# ------------------------------------------------------------------ Lauf

def schreiben(out_dir: str, eintraege: list[dict]) -> int:
    doc = {
        "version": 1,
        "generated": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
        "source": "www.elwis.de",
        "locks": eintraege,
    }
    daten = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode()
    ziel = os.path.join(out_dir, "locks.json.gz")
    tmp = ziel + ".tmp"
    with open(tmp, "wb") as f:
        f.write(gzip.compress(daten, 9, mtime=0))
    os.replace(tmp, ziel)
    return os.path.getsize(ziel)


def lauf(out_dir: str, seiten=None) -> None:
    """Ein ganzer Durchgang. [seiten] liefert das HTML je Schleuse, sonst ELWIS selbst."""
    t0 = time.time()
    elwis = Elwis()
    liste = schleusen(elwis.liste())
    if not liste:
        raise RuntimeError("Keine Schleusen in der Liste, hat ELWIS die Seite umgebaut?")
    osm = osm_schleusen(out_dir)
    eintraege, ohne_lage, ohne_zeiten = [], 0, 0
    for s in liste:
        lage = verorten(s, osm)
        if not lage:
            ohne_lage += 1
            continue
        try:
            z = zeiten(seiten(s["id"]) if seiten else elwis.seite(s["id"]))
        except Exception as e:  # eine kaputte Seite soll nicht den Lauf kosten
            print(f"  {s['name']}: {e}", flush=True)
            z = None
        if not seiten:
            time.sleep(PAUSE_S)
        if not z or not z["rows"]:
            ohne_zeiten += 1
            continue
        eintraege.append({"id": s["id"], "name": s["name"], "fairway": s["fairway"],
                          "points": lage, **z})
    groesse = schreiben(out_dir, eintraege)
    print(f"{time.strftime('%Y-%m-%d %H:%M')} {len(eintraege)} von {len(liste)} Schleusen, "
          f"{ohne_lage} ohne Lage, {ohne_zeiten} ohne Zeiten, {groesse // 1024} kB, "
          f"{time.time() - t0:.0f} s", flush=True)


def main() -> None:
    out_dir = sys.argv[1]
    if "--once" in sys.argv:
        lauf(out_dir)
        return
    while True:
        try:
            lauf(out_dir)
        except Exception as e:  # beim nächsten Mal wieder; die alte Datei bleibt liegen
            print(f"{time.strftime('%Y-%m-%d %H:%M')} Fehler: {e}", flush=True)
        time.sleep(INTERVAL_S)


if __name__ == "__main__":
    main()
