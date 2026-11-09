#!/usr/bin/env python3
"""Download complete ArcGIS layers via resultOffset pagination."""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import requests

OUT = Path("/workspace/QWEN_DOGRUDAN_VERI_20261108/INDIRILENLER/FULL")
OUT.mkdir(parents=True, exist_ok=True)
PAGE = 1000
SLEEP = 0.9
UA = "Mozilla/5.0 (compatible; IzmirFullLayerDownloader/1.0)"

SESSION = requests.Session()
SESSION.headers.update({"User-Agent": UA, "Accept": "*/*"})

JOBS = [
    ("Yol_Anayol", "https://kentrehberi.izmir.bel.tr/arcgis/rest/services/Rehber/CbsRehberGeoHybrid/MapServer", 2,
     "FULL_CbsRehberGeoHybrid_Yol_Anayol_L2.json"),
    ("Mahalle", "https://kentrehberi.izmir.bel.tr/arcgis/rest/services/Rehber/CbsRehberGeoGri/MapServer", 157,
     "FULL_CbsRehberGeoGri_Mahalle_L157.json"),
    ("Ilce_Alani", "https://kentrehberi.izmir.bel.tr/arcgis/rest/services/Rehber/CbsRehberGeoGri/MapServer", 155,
     "FULL_CbsRehberGeoGri_Ilce_Alani_L155.json"),
    ("IL_Alani", "https://kentrehberi.izmir.bel.tr/arcgis/rest/services/Rehber/CbsRehberGeoGri/MapServer", 151,
     "FULL_CbsRehberGeoGri_IL_Alani_L151.json"),
    ("Adalar", "https://kentrehberi.izmir.bel.tr/arcgis/rest/services/Rehber/CbsRehberGeoGri/MapServer", 189,
     "FULL_CbsRehberGeoGri_Adalar_L189.json"),
    ("YolOrtaHatti", "https://kentrehberi.izmir.bel.tr/arcgis/rest/services/Rehber/CbsRehberGeoHybrid/MapServer", 27,
     "FULL_CbsRehberGeoHybrid_YolOrtaHatti_L27.json"),
    ("Yapi", "https://kentrehberi.izmir.bel.tr/arcgis/rest/services/Rehber/CbsRehberGeoHybrid/MapServer", 94,
     "FULL_CbsRehberGeoHybrid_Yapi_L94.json"),
]


def get_json(url: str, params: dict | None = None, retries: int = 2) -> dict:
    last = None
    for i in range(retries):
        try:
            r = SESSION.get(url, params=params, timeout=300)
            r.raise_for_status()
            return r.json()
        except Exception as e:
            last = e
            if i + 1 < retries:
                time.sleep(4)
            else:
                raise last
    raise RuntimeError("unreachable")


def download_layer(name: str, mapserver: str, layer_id: int, outfile: str) -> None:
    out_path = OUT / outfile
    if out_path.exists() and out_path.stat().st_size > 1000:
        # verify complete
        # only skip if trailer says complete — for large files read tail
        try:
            with out_path.open("rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - 200))
                tail = f.read().decode("utf-8", "ignore")
            if '"complete": true' in tail or '"complete":true' in tail:
                print(f"SKIP {outfile}", flush=True)
                return
        except Exception:
            pass

    query = f"{mapserver}/{layer_id}/query"
    meta = get_json(f"{mapserver}/{layer_id}", {"f": "json"})
    if meta.get("error") and not meta.get("name"):
        raise RuntimeError(meta["error"])
    sr = (meta.get("extent") or {}).get("spatialReference")
    time.sleep(SLEEP)

    count_j = get_json(query, {"where": "1=1", "returnCountOnly": "true", "f": "json"})
    total = int(count_j["count"])
    print(f"=== {name} layer={layer_id} total={total}", flush=True)

    tmp = out_path.with_suffix(out_path.suffix + ".partial")
    if tmp.exists():
        tmp.unlink()

    got = 0
    offset = 0
    page_no = 0
    first = True

    with tmp.open("w", encoding="utf-8") as sw:
        sw.write("{")
        sw.write(f'"layerName":{json.dumps(name)},')
        sw.write(f'"layerId":{layer_id},')
        sw.write(f'"source":{json.dumps(query)},')
        sw.write(f'"expectedCount":{total},')
        sw.write(f'"spatialReference":{json.dumps(sr, ensure_ascii=False)},')
        sw.write('"features":[')

        while offset < total:
            page_no += 1
            params = {
                "where": "1=1",
                "outFields": "*",
                "returnGeometry": "true",
                "resultOffset": offset,
                "resultRecordCount": PAGE,
                "orderByFields": "OBJECTID ASC",
                "f": "json",
            }
            time.sleep(SLEEP)
            j = get_json(query, params)
            if j.get("error") and "features" not in j:
                raise RuntimeError(j["error"])
            feats = j.get("features") or []
            n = len(feats)
            if n == 0:
                print(f"  page {page_no}: empty at offset={offset}", flush=True)
                break
            chunk = json.dumps(feats, ensure_ascii=False)[1:-1]  # strip [ ]
            if not first:
                sw.write(",")
            sw.write(chunk)
            first = False
            got += n
            offset += n
            exceeded = bool(j.get("exceededTransferLimit"))
            print(
                f"  page {page_no}: +{n} ({got}/{total}) exceeded={exceeded}",
                flush=True,
            )
            if n < PAGE and not exceeded:
                break

        complete = got == total
        sw.write("],")
        sw.write(f'"featureCount":{got},')
        sw.write(f'"complete":{str(complete).lower()}')
        sw.write("}")

    if got != total:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"EKSIK {name}: expected={total} got={got}")

    tmp.replace(out_path)
    print(f"TAM OK {outfile} features={got} bytes={out_path.stat().st_size}", flush=True)


def main() -> int:
    only = set(sys.argv[1:]) if len(sys.argv) > 1 else None
    for name, ms, lid, fn in JOBS:
        if only and name not in only and fn not in only:
            continue
        try:
            download_layer(name, ms, lid, fn)
        except Exception as e:
            print(f"FAIL {name}: {type(e).__name__}: {e}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
