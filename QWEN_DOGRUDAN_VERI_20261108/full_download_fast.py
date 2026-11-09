#!/usr/bin/env python3
"""Faster full-layer download: objectIds batches + limited parallelism, resume shards."""
from __future__ import annotations

import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

OUT = Path("/workspace/QWEN_DOGRUDAN_VERI_20261108/INDIRILENLER/FULL")
OUT.mkdir(parents=True, exist_ok=True)
PAGE = 1000
WORKERS = 4
UA = "Mozilla/5.0 (compatible; IzmirFullLayerDownloader/1.1)"


def make_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({"User-Agent": UA, "Accept": "*/*"})
    retry = Retry(total=3, backoff_factor=1.5, status_forcelist=[502, 503, 504],
                  allowed_methods=["GET", "POST"])
    s.mount("https://", HTTPAdapter(max_retries=retry, pool_maxsize=WORKERS + 2))
    return s


def get_json(session: requests.Session, url: str, params: dict | None = None) -> dict:
    r = session.get(url, params=params, timeout=300)
    r.raise_for_status()
    return r.json()


def fetch_batch(session: requests.Session, query: str, ids: list[int], batch_idx: int) -> tuple[int, list]:
    # POST required: objectIds GET URL exceeds server/path limits (404).
    data = {
        "objectIds": ",".join(str(i) for i in ids),
        "outFields": "*",
        "returnGeometry": "true",
        "f": "json",
    }
    last = None
    for attempt in range(3):
        try:
            r = session.post(query, data=data, timeout=300)
            r.raise_for_status()
            j = r.json()
            break
        except Exception as e:
            last = e
            time.sleep(2 + attempt * 2)
    else:
        raise last  # type: ignore[misc]
    if j.get("error") and "features" not in j:
        raise RuntimeError(j["error"])
    feats = j.get("features") or []
    if len(feats) != len(ids):
        print(f"  WARN batch {batch_idx}: asked={len(ids)} got={len(feats)}", flush=True)
    return batch_idx, feats


def download_yapi() -> None:
    name = "Yapi"
    mapserver = "https://kentrehberi.izmir.bel.tr/arcgis/rest/services/Rehber/CbsRehberGeoHybrid/MapServer"
    layer_id = 94
    outfile = "FULL_CbsRehberGeoHybrid_Yapi_L94.json"
    out_path = OUT / outfile
    shard_dir = OUT / f"{outfile}.shards"
    shard_dir.mkdir(exist_ok=True)

    if out_path.exists() and out_path.stat().st_size > 1000:
        with out_path.open("rb") as f:
            f.seek(max(0, out_path.stat().st_size - 200))
            tail = f.read().decode("utf-8", "ignore")
        if '"complete":true' in tail.replace(" ", ""):
            print(f"SKIP {outfile}", flush=True)
            return

    session = make_session()
    query = f"{mapserver}/{layer_id}/query"
    meta = get_json(session, f"{mapserver}/{layer_id}", {"f": "json"})
    sr = (meta.get("extent") or {}).get("spatialReference")
    count = int(get_json(session, query, {"where": "1=1", "returnCountOnly": "true", "f": "json"})["count"])
    print(f"=== {name} total={count}", flush=True)

    ids_path = shard_dir / "objectids.json"
    if ids_path.exists():
        object_ids = json.loads(ids_path.read_text(encoding="utf-8"))
        print(f"resume objectIds from cache: {len(object_ids)}", flush=True)
    else:
        print("fetching objectIds...", flush=True)
        j = get_json(session, query, {"where": "1=1", "returnIdsOnly": "true", "f": "json"})
        object_ids = j.get("objectIds") or []
        ids_path.write_text(json.dumps(object_ids), encoding="utf-8")
        print(f"objectIds={len(object_ids)}", flush=True)

    if len(object_ids) != count:
        print(f"WARN count={count} objectIds={len(object_ids)}", flush=True)

    batches = [object_ids[i : i + PAGE] for i in range(0, len(object_ids), PAGE)]
    print(f"batches={len(batches)} workers={WORKERS}", flush=True)

    def need(batch_idx: int) -> bool:
        p = shard_dir / f"batch_{batch_idx:05d}.json"
        return not (p.exists() and p.stat().st_size > 2)

    todo = [i for i in range(len(batches)) if need(i)]
    print(f"todo batches={len(todo)} already={len(batches) - len(todo)}", flush=True)

    def worker(batch_idx: int):
        s = make_session()
        time.sleep(0.05 * (batch_idx % WORKERS))
        idx, feats = fetch_batch(s, query, batches[batch_idx], batch_idx)
        path = shard_dir / f"batch_{idx:05d}.json"
        path.write_text(json.dumps(feats, ensure_ascii=False), encoding="utf-8")
        return idx, len(feats)

    done = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = {ex.submit(worker, i): i for i in todo}
        for fut in as_completed(futs):
            idx, n = fut.result()
            done += 1
            if done % 10 == 0 or done == len(todo):
                print(f"  fetched {done}/{len(todo)} batches (last batch {idx} n={n})", flush=True)

    # assemble
    print("assembling...", flush=True)
    tmp = out_path.with_suffix(out_path.suffix + ".partial")
    got = 0
    with tmp.open("w", encoding="utf-8") as sw:
        sw.write("{")
        sw.write(f'"layerName":{json.dumps(name)},')
        sw.write(f'"layerId":{layer_id},')
        sw.write(f'"source":{json.dumps(query)},')
        sw.write(f'"expectedCount":{count},')
        sw.write(f'"spatialReference":{json.dumps(sr, ensure_ascii=False)},')
        sw.write('"features":[')
        first = True
        for i in range(len(batches)):
            p = shard_dir / f"batch_{i:05d}.json"
            feats = json.loads(p.read_text(encoding="utf-8"))
            if not feats:
                continue
            chunk = json.dumps(feats, ensure_ascii=False)[1:-1]
            if not first:
                sw.write(",")
            sw.write(chunk)
            first = False
            got += len(feats)
            if (i + 1) % 50 == 0:
                print(f"  assemble {i+1}/{len(batches)} got={got}", flush=True)
        complete = got == count
        sw.write("],")
        sw.write(f'"featureCount":{got},')
        sw.write(f'"complete":{str(complete).lower()}')
        sw.write("}")

    if got != count:
        raise RuntimeError(f"EKSIK expected={count} got={got}")
    tmp.replace(out_path)
    print(f"TAM OK {outfile} features={got} bytes={out_path.stat().st_size}", flush=True)


if __name__ == "__main__":
    download_yapi()
