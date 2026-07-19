import std/[os, strformat, times, algorithm, sequtils, json, tables]
import geo, h5read, interp, config, httputil

type
  RadarItem* = tuple[fname, href: string, dtIso: string]

  ScanInfo* = object
    items*: seq[RadarItem]
    scanDt*: Time # UTC
    dtIso*: string

proc extractFeature*(f: JsonNode): RadarItem =
  let idNode = f{"id"}
  if idNode == nil or idNode.kind != JString:
    raise newException(ValueError, "radar feature missing required 'id' field")
  result.fname = idNode.getStr()
  # {} is nil-safe; strict [] would raise KeyError on a missing nested key
  # (e.g. an asset.data object without "href").
  let asset = f{"asset"}
  if asset != nil and asset.kind == JObject:
    let hrefNode = if asset.hasKey("data"): asset{"data"}{"href"}
                   else: asset{"href"}
    if hrefNode != nil and hrefNode.kind == JString:
      result.href = hrefNode.getStr()
  let props = f{"properties"}
  if props != nil and props.hasKey("datetime"):
    result.dtIso = props["datetime"].getStr()

proc fetchNewestRadar*(collection: string): RadarItem =
  let url = &"{DmiRadarApi}/collections/{collection}/items?sortorder=datetime,DESC&limit=1"
  let data = httpGetJson(url)
  let feats = data{"features"}
  if feats == nil or feats.len == 0:
    raise newException(ValueError, "No radar files in collection '" &
        collection & "'")
  result = extractFeature(feats[0])
  if result.href.len == 0:
    raise newException(ValueError, "Newest radar file in collection '" &
        collection & "' has no download href")
  if result.dtIso.len == 0:
    raise newException(ValueError, "Newest radar file in collection '" &
        collection & "' has no datetime")

proc pickNewestScan*(feats: JsonNode, collection: string): ScanInfo =
  # Group by datetime, then pick the scan time with the most stations.
  # Pure (no HTTP) so the grouping logic is unit-testable.
  if feats == nil or feats.len == 0:
    raise newException(ValueError, "No radar files in collection '" &
        collection & "'")

  var byTime: Table[string, seq[RadarItem]] = initTable[string, seq[RadarItem]]()
  for f in feats:
    try:
      let item = extractFeature(f)
      if item.href.len > 0 and item.dtIso.len > 0:
        byTime.mgetOrPut(item.dtIso, @[]).add(item)
    except CatchableError:
      discard

  if byTime.len == 0:
    raise newException(ValueError, "No radar files with a downloadable href in collection '" &
        collection & "'")

  # Iterate datetime keys in descending order (ISO-8601 sorts lexically)
  # so ties favour the newest.
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

proc fetchNewestRadarSet*(collection: string, limit = 10): ScanInfo =
  let url = &"{DmiRadarApi}/collections/{collection}/items?sortorder=datetime,DESC&limit={limit}"
  let data = httpGetJson(url)
  result = pickNewestScan(data{"features"}, collection)

proc cleanStaleTmp() =
  # Remove leftover .h5.tmp files from a previous interrupted download.
  for f in walkFiles(DataDir / "*.h5.tmp"):
    try: removeFile(f)
    except CatchableError: discard

proc downloadH5(url, dest: string) =
  # Download to a sibling tmp file, then rename into place, so a crash
  # mid-download never leaves a partial .h5 behind. The HDF5 magic check
  # rejects error pages served with a 200 status before they get cached.
  let data = httpGetBytes(url, RadarFetchTimeoutMs)
  if data.len < 8 or data[0 ..< 4] != "\x89HDF":
    raise newException(ValueError, "radar download is not an HDF5 file (" &
        $data.len & " bytes)")
  let tmp = dest & ".tmp"
  writeFile(tmp, data)
  moveFile(tmp, dest)

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
    downloadH5(item.href, radarPath)
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
  downloadH5(item.href, radarPath)
  # Delete old .h5 files.
  for f in walkFiles(DataDir / "*.h5"):
    if f != radarPath:
      try: removeFile(f)
      except CatchableError: discard
  cleanStaleTmp()
  result = radarPath

proc parseRadarField*(paths: seq[string],
    collection: CollectionKind): RadarField =
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
    echo &"  pseudoCappi: {paths.len} radar(s) max-blended (grid {int((ext[1]-ext[0])/1000 + 0.5)} km)"
  of ckComposite:
    result = parseRadarH5(paths[0])
