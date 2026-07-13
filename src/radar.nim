import std/[os, strutils, strformat, times, algorithm, sequtils, json, tables]
import geo, h5read, interp, config, httputil

type
  RadarItem* = tuple[fname, href: string, dtIso: string]

  ScanInfo* = object
    items*: seq[RadarItem]
    scanDt*: Time       # UTC
    dtIso*: string

proc extractFeature*(f: JsonNode): RadarItem =
  let idNode = f{"id"}
  if idNode == nil or idNode.kind != JString:
    raise newException(ValueError, "radar feature missing required 'id' field")
  result.fname = idNode.getStr()
  let asset = f{"asset"}
  if asset != nil and asset.kind == JObject:
    if asset.hasKey("data"):
      result.href = asset["data"]["href"].getStr()
    elif asset.hasKey("href"):
      result.href = asset["href"].getStr()
  let props = f{"properties"}
  if props != nil and props.hasKey("datetime"):
    result.dtIso = props["datetime"].getStr()

proc fetchNewestRadar*(collection: string): RadarItem =
  let url = &"{DmiRadarApi}/collections/{collection}/items?sortorder=datetime,DESC&limit=1"
  let data = httpGetJson(url)
  let feats = data{"features"}
  if feats == nil or feats.len == 0:
    raise newException(ValueError, "No radar files in collection '" & collection & "'")
  result = extractFeature(feats[0])

proc fetchNewestRadarSet*(collection: string, limit = 10): ScanInfo =
  let url = &"{DmiRadarApi}/collections/{collection}/items?sortorder=datetime,DESC&limit={limit}"
  let data = httpGetJson(url)
  let feats = data{"features"}
  if feats == nil or feats.len == 0:
    raise newException(ValueError, "No radar files in collection '" & collection & "'")

  # Group by datetime.
  var byTime: Table[string, seq[RadarItem]] = initTable[string, seq[RadarItem]]()
  for f in feats:
    try:
      let item = extractFeature(f)
      if item.href.len > 0:
        byTime.mgetOrPut(item.dtIso, @[]).add(item)
    except CatchableError:
      discard

  # Sort by datetime descending; prefer the one with the most stations.
  var bestDt = ""
  var bestItems: seq[RadarItem] = @[]
  for dt in toSeq(byTime.keys).sorted(order = Descending):
    let items = byTime[dt]
    if bestItems.len == 0 or items.len > bestItems.len:
      bestDt = dt
      bestItems = items
    # If the newest already has most stations, stop early.
    if dt == bestDt and items.len >= max(1, byTime.len div 2 + 1):
      break

  result.items = bestItems
  result.dtIso = bestDt
  # Parse datetime.
  let s = bestDt.replace("Z", "+00:00")
  result.scanDt = parse(s, "yyyy-MM-dd'T'HH:mm:sszzz", utc()).toTime()

proc scanStamp*(si: ScanInfo): string =
  result = si.scanDt.format("yyyyMMdd-HHmm")

proc downloadAndCacheRadarSet*(si: ScanInfo): seq[string] =
  discard existsOrCreateDir(DataDir)
  var
    h5Paths: seq[string] = @[]
    downloaded = false
  for item in si.items:
    let radarPath = DataDir / item.fname
    if fileExists(radarPath):
      h5Paths.add(radarPath)
      continue
    if not downloaded:
      echo "Downloading radar files..."
      downloaded = true
    let data = httpGetBytes(item.href, 180000)
    let tmp = radarPath & ".tmp"
    writeFile(tmp, data)
    moveFile(tmp, radarPath)
    h5Paths.add(radarPath)
  if not downloaded:
    echo "All radar files already cached; skipping download."
  # Delete old .h5 files not in current set.
  let keepSet = h5Paths.mapIt(it.absolutePath)
  for f in walkFiles(DataDir / "*.h5"):
    if f.absolutePath notin keepSet:
      try: removeFile(f)
      except CatchableError: discard
  result = h5Paths

proc downloadAndCacheRadarSingle*(item: RadarItem): string =
  discard existsOrCreateDir(DataDir)
  let radarPath = DataDir / item.fname
  if fileExists(radarPath):
    echo "Newest radar already cached; skipping download."
    return radarPath
  echo "Downloading radar file..."
  let data = httpGetBytes(item.href, 180000)
  let tmp = radarPath & ".tmp"
  writeFile(tmp, data)
  moveFile(tmp, radarPath)
  # Delete old .h5 files.
  for f in walkFiles(DataDir / "*.h5"):
    if f != radarPath:
      try: removeFile(f)
      except CatchableError: discard
  result = radarPath

proc parseRadarField*(paths: seq[string], collection: CollectionKind): RadarField =
  case collection
  of ckPseudoCappi:
    let outProj = dkCompositeProjection()
    var stations: seq[PseudoCappiStation] = @[]
    for p in paths:
      let st = readPseudoCappiStation(p)
      let n = st.dbz.shape.data[0] * st.dbz.shape.data[1]
      echo &"    {extractFilename(p)}: {n} bins"
      stations.add(st)
    result = compositePseudoCappi(stations, outProj)
    let ext = result.extent
    echo &"  pseudoCappi: {paths.len} radar(s) max-blended (grid {(ext[1]-ext[0])/1000:.0f} km)"
  of ckComposite:
    result = parseRadarH5(paths[0])
