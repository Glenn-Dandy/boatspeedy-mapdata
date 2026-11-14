#!/usr/bin/env python3
"""Holt die Nachrichten für die Binnenschifffahrt von ELWIS und legt sie als JSON ab.

ELWIS bietet sie über eine SOAP-Schnittstelle nach EU-Norm an (NtS 4.0). Die Antwort für
einen Tag ist rund 1,5 MB XML und braucht eine halbe Minute; das soll nicht jedes Handy
selbst tun. Hier wird sie einmal abgeholt und auf das Nötige gekürzt: Text, Zeitraum,
Ort und Art der Einschränkung. Die App lädt davon wenige Kilobyte.

Die Texte bleiben unverändert. So verlangen es die Nutzungsbedingungen von ELWIS
(Open Data, Quelle www.elwis.de, Inhalt unverändert).

Aufruf: nts.py <ausgabeverzeichnis> [--once]
"""
import datetime as dt
import gzip
import json
import os
import re
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

URL = "https://nts40.elwis.de/server/web/MessageServer.php"
NTS = "http://www.ris.eu/nts/4.0.4.0"
MS = "http://www.ris.eu/nts.ms/2.0.4.0"

# Alle halbe Stunde. ELWIS ändert sich nicht minütlich, und eine Abfrage kostet den
# Server dort spürbar Arbeit.
INTERVAL_S = 30 * 60

# Was heute gilt und in den nächsten Tagen beginnt: Eine angekündigte Sperrung will
# man vor der Fahrt kennen, nicht erst am Tor.
VORLAUF_TAGE = 7


def abfrage(heute: dt.date) -> bytes:
    bis = heute + dt.timedelta(days=VORLAUF_TAGE)
    body = f"""<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ms="{MS}" xmlns:nts="{NTS}">
<soapenv:Body><ms:get_messages_query><message_type>FTM</message_type>
<validity_period><nts:date_start>{heute.isoformat()}</nts:date_start><nts:date_end>{bis.isoformat()}</nts:date_end></validity_period>
</ms:get_messages_query></soapenv:Body></soapenv:Envelope>""".encode()
    req = urllib.request.Request(URL, data=body, headers={
        "Content-Type": "text/xml; charset=utf-8",
        "SOAPAction": '"http://www.ris.eu/nts.ms/get_messages"',
        "User-Agent": "boatspeedy-mapdata (+https://github.com/Glenn-Dandy/boatspeedy-mapdata)",
    })
    with urllib.request.urlopen(req, timeout=180) as r:
        return r.read()


def _t(e, name):
    """Text eines direkten Kindes, oder None."""
    c = e.find(f"{{{NTS}}}{name}")
    return c.text.strip() if c is not None and c.text else None


def koordinate(s: str | None) -> float | None:
    """ "52 31.863 N" -> 52.53105. Grad und Dezimalminuten, Süd und West negativ."""
    if not s:
        return None
    m = re.fullmatch(r"\s*(\d+)\s+(\d+(?:\.\d+)?)\s*([NSEW])\s*", s)
    if not m:
        return None
    v = int(m.group(1)) + float(m.group(2)) / 60
    return round(-v if m.group(3) in "SW" else v, 6)


def datum(s: str | None) -> str | None:
    """ "2026-11-13+01:00" -> "2026-11-13". Der Zeitzonenrest hilft beim Datum nicht."""
    return s[:10] if s else None


def zeit(s: str | None) -> str | None:
    """ "13:20:00" -> "13:20" """
    return s[:5] if s else None


def ort(e) -> dict | None:
    """Ein Objekt oder ein Streckenabschnitt mit seinen Einschränkungen."""
    punkte = []
    name = fairway = typ = None
    for g in e.findall(f"{{{NTS}}}geo_object"):
        name = name or _t(g, "name")
        fairway = fairway or _t(g, "fairway_name")
        typ = typ or _t(g, "type_code")
        for c in g.findall(f"{{{NTS}}}coordinate"):
            lat, lon = koordinate(_t(c, "lat")), koordinate(_t(c, "long"))
            if lat is not None and lon is not None:
                punkte.append([lat, lon])
    if not punkte:
        return None
    limits = []
    for lim in e.findall(f"{{{NTS}}}limitation"):
        perioden = []
        for p in lim.findall(f"{{{NTS}}}limitation_period"):
            perioden.append({k: v for k, v in {
                "from": datum(_t(p, "date_start")),
                "to": datum(_t(p, "date_end")),
                "tfrom": zeit(_t(p, "time_start")),
                "tto": zeit(_t(p, "time_end")),
                "interval": _t(p, "interval_code"),
            }.items() if v})
        limits.append({k: v for k, v in {
            "code": _t(lim, "limitation_code"),
            "value": _t(lim, "value"),
            "unit": _t(lim, "unit"),
            "periods": perioden,
        }.items() if v})
    return {k: v for k, v in {
        "name": name,
        "type": typ,
        "fairway": fairway,
        "section": e.tag.endswith("fairway_section"),
        "points": punkte,
        "limits": limits,
    }.items() if v not in (None, [], False)}


def auswerten(xml: bytes) -> list[dict]:
    """Die gültigen Meldungen. Von jeder Nummer nur die letzte Fassung, aufgehobene fallen weg."""
    root = ET.fromstring(xml)
    fehler = [e.text for e in root.iter(f"{{{MS}}}result_error")]
    if fehler:
        raise RuntimeError("ELWIS meldet Fehler: " + ", ".join(fehler))
    neueste: dict[str, tuple[int, dict | None]] = {}
    for m in root.iter(f"{{{MS}}}result_message"):
        ident = m.find(f"{{{NTS}}}identification")
        ftm = m.find(f"{{{NTS}}}ftm")
        if ftm is None:
            continue
        nr = ftm.find(f"{{{NTS}}}nts_number")
        schluessel = f"{_t(nr, 'year')}-{_t(nr, 'number')}"
        folge = int(_t(nr, "serial_number") or 0)
        if schluessel in neueste and neueste[schluessel][0] >= folge:
            continue
        if _t(ftm, "subject_code") == "CANCEL":
            neueste[schluessel] = (folge, None)
            continue
        orte = [o for e in ftm if e.tag in (f"{{{NTS}}}object", f"{{{NTS}}}fairway_section")
                if (o := ort(e))]
        if not orte:
            continue
        gueltig = ftm.find(f"{{{NTS}}}validity_period")
        neueste[schluessel] = (folge, {k: v for k, v in {
            "id": schluessel,
            "subject": _t(ftm, "subject_code"),
            "issued": _t(ident, "date_issue") if ident is not None else None,
            "from": datum(_t(gueltig, "date_start")) if gueltig is not None else None,
            "to": datum(_t(gueltig, "date_end")) if gueltig is not None else None,
            "text": _t(ftm, "contents"),
            "by": _t(ftm, "source"),
            "reason": _t(ftm, "reason_code"),
            "places": orte,
        }.items() if v})
    return sorted((m for _, m in neueste.values() if m), key=lambda m: m["id"])


def schreiben(out_dir: str, meldungen: list[dict]) -> int:
    doc = {
        "version": 1,
        "generated": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
        "source": "www.elwis.de",
        "messages": meldungen,
    }
    daten = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode()
    ziel = os.path.join(out_dir, "nts.json.gz")
    tmp = ziel + ".tmp"
    with open(tmp, "wb") as f:
        f.write(gzip.compress(daten, 9, mtime=0))
    # Umbenennen ist unteilbar: Wer gerade lädt, bekommt die alte Datei oder die neue.
    os.replace(tmp, ziel)
    return os.path.getsize(ziel)


def lauf(out_dir: str) -> None:
    t0 = time.time()
    xml = abfrage(dt.date.today())
    meldungen = auswerten(xml)
    groesse = schreiben(out_dir, meldungen)
    print(f"{time.strftime('%Y-%m-%d %H:%M')} {len(meldungen)} Meldungen, "
          f"{len(xml) // 1024} kB geholt, {groesse // 1024} kB abgelegt, {time.time() - t0:.0f} s", flush=True)


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
