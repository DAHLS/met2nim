import std/[os, strutils, strformat, times, math]
import arraymancer, pixie
import config, h5read, radar, wind, sat, coast, render

const coastData = staticRead("../coast.geojson")

proc printUsage() =
  echo """met2img-nim - Render DMI radar + wind on a satellite map.

Usage: met2img [options]

Options:
  --outdir DIR        Output directory (default: .)
  --collection NAME   Radar collection: composite, pseudoCappi (default)
  --sat-source NAME   Satellite source: geocolour (default), eumetsat-mtg,
                      eumetsat-msg, gibs-modis, none
  --no-satellite      Skip satellite background (shortcut for --sat-source none)
  --no-wind           Skip wind arrows
  --min-dbz N         Mask radar echoes below N dBZ (default 10)
  --despeckle         Remove isolated single-pixel echoes
  --zoom N            Zoom factor (default 1.0)
"""

proc parseCli(): AppConfig =
  result = defaultConfig()
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let a = args[i]
    if a.startsWith("--"):
      let eq = a.find('=')
      let key = if eq > 0: a[2 ..< eq] else: a[2 .. ^1]
      let needsVal = key in ["outdir", "collection", "sat-source", "min-dbz", "zoom"]
      let val = if eq > 0: a[eq + 1 .. ^1]
                elif needsVal and i + 1 < args.len:
                  inc i; args[i]
                else: ""
      case key
      of "outdir": result.outDir = val
      of "collection":
        case val.toLowerAscii()
        of "composite": result.collection = ckComposite
        of "pseudocappi", "pseudocapi": result.collection = ckPseudoCappi
        else:
          echo "Unknown collection: " & val
          quit(1)
      of "no-satellite": result.noSatellite = true
      of "sat-source":
        case val.toLowerAscii()
        of "geocolour": result.satSource = ssGeocolour
        of "eumetsat-mtg": result.satSource = ssEumetsatMtg
        of "eumetsat-msg": result.satSource = ssEumetsatMsg
        of "gibs-modis", "gibs_modis": result.satSource = ssGibsModis
        of "none": result.satSource = ssNone
        else:
          echo "Unknown sat-source: " & val
          quit(1)
      of "no-wind": result.noWind = true
      of "min-dbz": result.minDbz = parseFloat(val)
      of "despeckle": result.despeckle = true
      of "zoom": result.zoom = parseFloat(val)
      of "help", "h":
        printUsage()
        quit(0)
      else:
        echo "Unknown option: --" & key
        quit(1)
    elif a == "-h":
      printUsage()
      quit(0)
    inc i

proc main() =
  let cfg = parseCli()

  let collectionName = if cfg.collection == ckComposite: "composite" else: "pseudoCappi"
  echo &"Fetching newest {collectionName} radar file metadata..."

  let multiStation = cfg.collection == ckPseudoCappi

  var
    h5Paths: seq[string]
    scanDt: Time
    dtIso: string

  if multiStation:
    let si = fetchNewestRadarSet(collectionName)
    scanDt = si.scanDt
    dtIso = si.dtIso
    echo &"  newest: {si.items.len} stations @ {scanDt.utc.format(\"yyyy-MM-dd HH:mm 'UTC'\")}"
    for item in si.items:
      echo "    " & item.fname
    h5Paths = downloadAndCacheRadarSet(si)
  else:
    let item = fetchNewestRadar(collectionName)
    dtIso = item.dtIso
    let s = dtIso.replace("Z", "+00:00")
    scanDt = parse(s, "yyyy-MM-dd'T'HH:mm:sszzz", utc()).toTime()
    echo &"  newest: {item.fname}  ({scanDt.utc.format(\"yyyy-MM-dd HH:mm 'UTC'\")})"
    h5Paths = @[downloadAndCacheRadarSingle(item)]

  # Wind cache path.
  let stamp = scanDt.utc.format("yyyyMMdd-HHmm")
  let windPath = DataDir / "wind_" & stamp & ".json"

  echo "Parsing radar data..."
  let rf = parseRadarField(h5Paths, cfg.collection)
  # Report reflectivity range.
  var minVal = Inf
  var maxVal = -Inf
  for v in rf.dbz:
    if v == v:  # not NaN
      minVal = min(minVal, float(v))
      maxVal = max(maxVal, float(v))
  echo &"  reflectivity range: {minVal:.1f} to {maxVal:.1f} dBZ"

  # Wind data.
  var windStations: seq[WindStation] = @[]
  if not cfg.noWind:
    if fileExists(windPath):
      windStations = loadWindCache(windPath)
      echo &"Wind cache hit: {windStations.len} stations ({scanDt.utc.format(\"HH:mm 'UTC'\")})"
    else:
      echo &"Fetching wind observations near {scanDt.utc.format(\"HH:mm 'UTC'\")}..."
      try:
        windStations = fetchWindAt(scanDt)
        discard existsOrCreateDir(DataDir)
        saveWindCache(windPath, windStations)
        echo &"  {windStations.len} stations with wind_dir+wind_speed (cached)"
      except Exception as e:
        echo &"  warning: wind fetch failed ({e.msg})"
      # Clean up old wind JSON files.
      for f in walkFiles(DataDir / "wind_*.json"):
        if f != windPath:
          try: removeFile(f)
          except: discard

  let windArrows = if not cfg.noWind: assignWindToSites(windStations, WindSites)
                   else: @[]

  # Satellite.
  var satImg: Image = nil
  var satBbox: tuple[w, s, e, n: float64] = (0, 0, 0, 0)
  let satSource = if cfg.noSatellite: ssNone else: cfg.satSource
  if satSource != ssNone:
    satImg = fetchSatellite(satSource, rf.proj, scanDt, cfg.zoom)
    if not satImg.isNil:
      satBbox = viewGeographicBbox(rf.proj, cfg.zoom)

  # Coastlines (embedded in binary at compile time via staticRead).
  let coastlines = loadCoastlines(coastData)

  echo "Rendering image..."
  let renderArgs = RenderArgs(
    useSatellite: satSource != ssNone and not satImg.isNil,
    useWind: not cfg.noWind,
    zoom: cfg.zoom,
    minDbz: cfg.minDbz,
    despeckle: cfg.despeckle,
    satImage: satImg,
    satBbox: satBbox,
    coastlines: coastlines,
    windArrows: windArrows,
  )
  let img = renderImage(rf, dtIso, renderArgs)
  saveImage(img, cfg.outDir, stamp)

main()
