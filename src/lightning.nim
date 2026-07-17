import std/[os, strformat, times, json, tables]
import config, httputil

type
  LightningStrike* = object
    id*: string     # DMI feature id (stable across responses — dedup key)
    lon*, lat*: float64
    observed*: Time # UTC strike time

  # Persistent cache: the most recent scanTime fetched up to, plus every
  # strike observed within the rolling 3h window ending at that scanTime.
  LightningCache* = object
    lastFetch*: Time # scanTime of the last successful fetch
    strikes*: seq[LightningStrike]

# --- Opacity aging ---
# Linear fade: 100% at 0h → 0% at 3h, deleted after 3h. Anchored to the
# radar scan timestamp (see LightningWindowHours).
proc lightningOpacity*(ageHours: float64): float32 =
  if ageHours < 0.0:
    return 1.0
  let op = 1.0 - ageHours / LightningWindowHours
  if op <= 0.0:
    return 0.0
  result = float32(op)

# --- Cache JSON ---
# Layout: { "lastFetch": "<iso>", "strikes": [[id, lon, lat, iso], ...] }
# Kept deliberately close to wind.nim's saveWindCache/loadWindCache style.

proc saveLightningCache*(path: string, cache: LightningCache) =
  var root = newJObject()
  root["lastFetch"] = newJString(formatIsoUtc(cache.lastFetch))
  var arr = newJArray()
  for s in cache.strikes:
    var row = newJArray()
    row.add(newJString(s.id))
    row.add(newJFloat(s.lon))
    row.add(newJFloat(s.lat))
    row.add(newJString(formatIsoUtc(s.observed)))
    arr.add(row)
  root["strikes"] = arr
  writeFile(path, $root)

proc loadLightningCache*(path: string): LightningCache =
  if not fileExists(path):
    return
  let data = parseFile(path)
  let lf = data{"lastFetch"}
  if lf != nil and lf.kind == JString:
    result.lastFetch = parseIsoUtc(lf.getStr())
  let arr = data{"strikes"}
  if arr != nil and arr.kind == JArray:
    for row in arr:
      if row.len < 4: continue
      let id = row[0].getStr()
      let lon = row[1].getFloat()
      let lat = row[2].getFloat()
      let obs = parseIsoUtc(row[3].getStr())
      result.strikes.add(LightningStrike(id: id, lon: lon, lat: lat,
          observed: obs))

# --- Response parsing ---
# OGC API Features: features[].{id, geometry.coordinates[lon,lat], properties.observed}
proc extractStrike(f: JsonNode): LightningStrike =
  let idNode = f{"id"}
  if idNode == nil or idNode.kind != JString:
    raise newException(ValueError, "lightning feature missing 'id'")
  result.id = idNode.getStr()
  let coords = f{"geometry"}{"coordinates"}
  if coords == nil or coords.len < 2:
    raise newException(ValueError, "lightning feature missing coordinates")
  result.lon = coords[0].getFloat()
  result.lat = coords[1].getFloat()
  let obs = f{"properties"}{"observed"}
  if obs == nil or obs.kind != JString:
    raise newException(ValueError, "lightning feature missing 'observed'")
  result.observed = parseIsoUtc(obs.getStr())

# Follow `rel="next"` links until exhausted or the safety cap is hit. Each
# page carries a "next" link with an offset parameter when more results
# remain; the response also includes numberReturned as a fallback signal.
proc fetchLightningPage(loStr, hiStr: string): seq[LightningStrike] =
  let baseUrl = &"{DmiLightningApi}/collections/observation/items"
  var url = &"{baseUrl}?datetime={loStr}/{hiStr}&bbox={LightningBbox}" &
            &"&limit={LightningFetchLimit}&sortorder=observed,DESC"
  var pages = 0
  while pages < LightningMaxPages:
    let data = httpGetJson(url)
    let feats = data{"features"}
    if feats != nil and feats.kind == JArray:
      for f in feats:
        try: result.add(extractStrike(f))
        except CatchableError as e:
          stderr.writeLine(&"warning: lightning feature parse failed ({e.msg})")
    # Look for a next page link.
    var nextHref = ""
    let links = data{"links"}
    if links != nil and links.kind == JArray:
      for l in links:
        if l{"rel"}.getStr() == "next":
          let h = l{"href"}
          if h != nil and h.kind == JString:
            nextHref = h.getStr()
          break
    # Fallback heuristic: a full page without an explicit next link is
    # suspicious — treat it as paginated anyway.
    let nReturned = data{"numberReturned"}
    let n = if nReturned != nil and nReturned.kind == JInt: nReturned.getInt() else: 0
    if nextHref.len == 0:
      if n < LightningFetchLimit:
        return # complete
      # No next link but a full page: log and stop to avoid an infinite loop.
      stderr.writeLine("warning: lightning page full but no next link; results may be truncated")
      return
    url = nextHref
    inc pages
  stderr.writeLine(&"warning: lightning fetch hit {LightningMaxPages}-page cap; results may be truncated")

# --- Merge + prune ---
# Merge newly fetched strikes into the cache (dedup by id — a strike's id is
# stable across responses, so re-fetching the overlap window is harmless),
# then drop anything older than the 3h window ending at scanTime. lastFetch
# is advanced to scanTime only when the fetch actually ran.

proc mergeAndPrune*(cache: var LightningCache, fetched: seq[LightningStrike],
                    scanTime: Time, didFetch: bool) =
  if didFetch:
    # Merge: keep existing, append new not already present.
    var seen: Table[string, bool] = initTable[string, bool]()
    for s in cache.strikes:
      seen[s.id] = true
    for s in fetched:
      if not seen.getOrDefault(s.id, false):
        cache.strikes.add(s)
        seen[s.id] = true
    cache.lastFetch = scanTime
  # Prune: drop strikes older than the rolling window.
  let cutoff = scanTime - initDuration(hours = int(LightningWindowHours))
  var kept: seq[LightningStrike] = @[]
  for s in cache.strikes:
    if s.observed >= cutoff:
      kept.add(s)
  cache.strikes = kept

# --- Public entry point ---
# Returns the renderable set of strikes (all within the 3h window ending at
# scanTime). The cache is a persistent rolling file at data/lightning.json:
#   - empty / missing        → full fetch scanTime-3h .. scanTime, reset cache
#   - lastFetch >= scanTime  → skip fetch (manual rerun of older radar), just prune
#   - otherwise              → incremental fetch (lastFetch - overlap) .. scanTime
# Failures are non-fatal: a fetch error leaves the existing cache intact and
# returns whatever is already cached (possibly empty).

proc acquireLightning*(scanTime: Time, cachePath = DataDir /
    LightningCacheFile): seq[LightningStrike] =
  var cache = loadLightningCache(cachePath)
  let
    nowStr = formatIsoUtc(scanTime)
    fullLo = formatIsoUtc(scanTime - initDuration(hours = int(
        LightningWindowHours)))

  if cache.lastFetch == Time() and cache.strikes.len == 0:
    echo &"Lightning cache empty; fetching full {LightningWindowHours:.0f}h window..."
    try:
      let fetched = fetchLightningPage(fullLo, nowStr)
      echo &"  fetched {fetched.len} strikes"
      mergeAndPrune(cache, fetched, scanTime, didFetch = true)
    except CatchableError as e:
      stderr.writeLine(&"  warning: lightning fetch failed ({e.msg}); using existing cache")
      mergeAndPrune(cache, @[], scanTime, didFetch = false)
  elif cache.lastFetch >= scanTime:
    # Regression guard: scanTime not newer than lastFetch (e.g. manual rerun
    # against an older cached radar). No fetch; just re-prune against the
    # new scanTime so opacity/ageing stays correct.
    mergeAndPrune(cache, @[], scanTime, didFetch = false)
  else:
    let lo = formatIsoUtc(cache.lastFetch - initDuration(
        minutes = LightningFetchOverlapMinutes))
    echo &"Fetching lightning incrementally ({LightningFetchOverlapMinutes}-min overlap)..."
    try:
      let fetched = fetchLightningPage(lo, nowStr)
      echo &"  fetched {fetched.len} new strikes"
      mergeAndPrune(cache, fetched, scanTime, didFetch = true)
    except CatchableError as e:
      stderr.writeLine(&"  warning: lightning fetch failed ({e.msg}); using existing cache")
      mergeAndPrune(cache, @[], scanTime, didFetch = false)

  discard existsOrCreateDir(DataDir)
  saveLightningCache(cachePath, cache)
  result = cache.strikes
