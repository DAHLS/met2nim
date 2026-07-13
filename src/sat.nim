import std/[strformat, times, math]
import pixie
import geo, config, httputil

proc viewGeographicBbox*(proj: Projection, zoom: float64): tuple[w, s, e, n: float64] =
  let ext = proj.viewExtent(zoom)
  let n = 50
  var
    lons: seq[float64] = @[]
    lats: seq[float64] = @[]
  for i in 0 ..< n:
    let t = float64(i) / float64(n - 1)
    lons.add(ext[0] + (ext[1] - ext[0]) * t)
    lats.add(ext[2])
    lons.add(ext[0] + (ext[1] - ext[0]) * t)
    lats.add(ext[3])
    lons.add(ext[0])
    lats.add(ext[2] + (ext[3] - ext[2]) * t)
    lons.add(ext[1])
    lats.add(ext[2] + (ext[3] - ext[2]) * t)
  var
    lonMin = Inf
    lonMax = -Inf
    latMin = Inf
    latMax = -Inf
  for i in 0 ..< lons.len:
    let (lat, lon) = proj.inverse(lons[i], lats[i])
    lonMin = min(lonMin, lon)
    lonMax = max(lonMax, lon)
    latMin = min(latMin, lat)
    latMax = max(latMax, lat)
  result.w = max(lonMin, -WmsExtentLimit)
  result.e = min(lonMax, WmsExtentLimit)
  result.s = max(latMin, -WmsExtentLimit)
  result.n = min(latMax, WmsExtentLimit)

proc fetchEumetsat*(layer: string, cadence: int,
                    proj: Projection, scanDt: Time, zoom: float64): Image =
  let dt = scanDt.utc()
  let snapped = scanDt - initDuration(
    minutes = dt.minute mod cadence,
    seconds = dt.second,
    nanoseconds = dt.nanosecond,
  )
  let tIso = snapped.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let bbox = viewGeographicBbox(proj, zoom)

  let url = &"{EumWmsUrl}?service=WMS&request=GetMap&version=1.3.0" &
            &"&layers={layer}&styles=&format=image/png&transparent=true" &
            &"&time={tIso}&width={EumFetchW}&height={EumFetchH}" &
            &"&crs=CRS:84&bbox={bbox.w:.6f},{bbox.s:.6f},{bbox.e:.6f},{bbox.n:.6f}"

  echo &"satellite: EUMETSAT {layer} @ {tIso} ({EumFetchW}x{EumFetchH}, view {bbox.w:.1f},{bbox.s:.1f},{bbox.e:.1f},{bbox.n:.1f})"

  let pngData = httpGetBytes(url, 180000)
  result = decodeImage(pngData)

proc gibsProbeDate*(dateStr: string): bool =
  # Probe a small tile over central Europe to check if GIBS has real
  # (non-black) tiles for this date. GIBS MODIS Terra has a ~24h
  # processing lag — tiles may exist but be entirely black.
  let probeBbox = "8.0,54.0,12.0,58.0"
  let url = &"{GibsWmsUrl}?service=WMS&request=GetMap&version=1.3.0" &
            &"&layers={GobsLayer}&styles=&format=image/jpeg" &
            &"&time={dateStr}&width=100&height=100" &
            &"&crs=CRS:84&bbox={probeBbox}"
  try:
    let jpgData = httpGetBytes(url, 30000)
    let img = decodeImage(jpgData)
    # Check if image is entirely black (max pixel == 0).
    for px in img.data:
      if px.r > 0 or px.g > 0 or px.b > 0:
        return true
    return false
  except CatchableError:
    return false

proc fetchGibs*(proj: Projection, scanDt: Time, zoom: float64): Image =
  let bbox = viewGeographicBbox(proj, zoom)

  # Step back up to 3 days to find the most recent date with real tiles.
  var date = scanDt.utc()
  var chosen = ""
  for attempt in 0 ..< 3:
    let dateStr = date.format("yyyy-MM-dd")
    if gibsProbeDate(dateStr):
      chosen = dateStr
      break
    date = date - 1.days
  if chosen == "":
    chosen = scanDt.utc().format("yyyy-MM-dd")

  let url = &"{GibsWmsUrl}?service=WMS&request=GetMap&version=1.3.0" &
            &"&layers={GobsLayer}&styles=&format=image/jpeg" &
            &"&time={chosen}&width={EumFetchW}&height={EumFetchH}" &
            &"&crs=CRS:84&bbox={bbox.w:.6f},{bbox.s:.6f},{bbox.e:.6f},{bbox.n:.6f}"

  echo &"satellite: GIBS {GobsLayer} @ {chosen} ({EumFetchW}x{EumFetchH}, view {bbox.w:.1f},{bbox.s:.1f},{bbox.e:.1f},{bbox.n:.1f})"

  let jpgData = httpGetBytes(url, 180000)
  result = decodeImage(jpgData)

proc fetchSatellite*(source: SatSource, proj: Projection,
                     scanDt: Time, zoom: float64): Image =
  if source == ssNone:
    return nil

  if source == ssGibsModis:
    return fetchGibs(proj, scanDt, zoom)

  # EUMETSAT path (with fallback to GIBS on failure).
  let (layer, cadence) = eumLayer(source)
  try:
    return fetchEumetsat(layer, cadence, proj, scanDt, zoom)
  except CatchableError as e:
    stderr.writeLine(&"warning: EUMETSAT satellite failed ({e.msg}); falling back to GIBS daily MODIS")
    try:
      return fetchGibs(proj, scanDt, zoom)
    except CatchableError as e2:
      stderr.writeLine(&"warning: GIBS satellite also failed ({e2.msg}); continuing without it")
      return nil
