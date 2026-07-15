import std/[os, strformat, times, algorithm, sequtils, json, tables]
import geo, h5read, interp, config, httputil

type
  RadarItem* = tuple[fname, href: string, dtIso: string]

  ScanInfo* = object
    items*: seq[RadarItem]
    scanDt*: Time       # UTC
    dtIso*: string

proc extractFeature(f: JsonNode): RadarItem =
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

  if byTime.len == 0:
    raise newException(ValueError, "No radar files with a downloadable href in collection '" & collection & "'")

  # Pick the scan time with the most stations. Iterate datetime keys in
  # descending order (ISO-8601 sorts lexically) so ties favour the newest.
  var bestDt = ""
  var bestItems: seq[RadarItem] = @[]
  for dt in toSeq(byTime.keys).sorted(order = Descending):
    let items = byTime[dt]
    if bestItems.len == 0 or items.len > bestItems.len:
      bestDt = dt
      bestItems = items

  result.items = bestItems
  result.dtIso = bestDt
  result.scanDt = parseIsoUtc(bestDt)

proc cleanStaleTmp() =
  # Remove leftover .h5.tmp files from a previous interrupted download.
  for f in walkFiles(DataDir / "*.h5.tmp"):
    try: removeFile(f)
    except CatchableError: discard

proc downloadAndCacheRadarSet*(si: ScanInfo): seq[string] =
  discard existsOrCreateDir(DataDir)
  cleanStaleTmp()
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
    let data = httpGetBytes(item.href, RadarFetchTimeoutMs)
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
  cleanStaleTmp()
  result = h5Paths

proc downloadAndCacheRadarSingle*(item: RadarItem): string =
  discard existsOrCreateDir(DataDir)
  cleanStaleTmp()
  let radarPath = DataDir / item.fname
  if fileExists(radarPath):
    echo "Newest radar already cached; skipping download."
    return radarPath
  echo "Downloading radar file..."
  let data = httpGetBytes(item.href, RadarFetchTimeoutMs)
  let tmp = radarPath & ".tmp"
  writeFile(tmp, data)
  moveFile(tmp, radarPath)
  # Delete old .h5 files.
  for f in walkFiles(DataDir / "*.h5"):
    if f != radarPath:
      try: removeFile(f)
      except CatchableError: discard
  cleanStaleTmp()
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
