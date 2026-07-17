import std/[strformat, times, math, tables, json]
import geo, config, httputil

type
  WindStation* = tuple[lon, lat, dirFrom, speed: float64]

proc acceptValue*(n: JsonNode): bool =
  n != nil and n.kind in {JFloat, JInt}

proc fetchWindAt*(scanDt: Time, windowMinutes = 10): seq[WindStation] =
  let
    lo = scanDt - initDuration(minutes = windowMinutes)
    hi = scanDt + initDuration(minutes = windowMinutes)
  let dtRange = formatIsoUtc(lo) & "/" & formatIsoUtc(hi)

  proc fetch(param: string): JsonNode =
    let url = &"{DmiMetObsApi}/collections/observation/items?parameterId={param}&datetime={dtRange}&bbox={WindBbox}&limit={WindFetchLimit}"
    httpGetJson(url){"features"}

  let dfeats = fetch("wind_dir")
  let sfeats = fetch("wind_speed")
  if dfeats == nil or sfeats == nil or dfeats.len == 0 or sfeats.len == 0:
    return @[]

  # Speed: nearest observation per station.
  var spdBy: Table[string, tuple[delta: int64, speed: float64]] = initTable[
      string, tuple[delta: int64, speed: float64]]()
  for f in sfeats:
    let p = f{"properties"}
    if p == nil: continue
    if not acceptValue(p{"value"}): continue
    let sidNode = p{"stationId"}
    let obsNode = p{"observed"}
    if sidNode == nil or obsNode == nil: continue
    let sid = sidNode.getStr()
    let obsStr = obsNode.getStr()
    let t = parseIsoUtc(obsStr)
    let delta = abs((t - scanDt).inSeconds)
    if sid notin spdBy or delta < spdBy[sid].delta:
      spdBy[sid] = (delta, p{"value"}.getFloat())

  # Direction: nearest observation per station.
  var dirBest: Table[string, tuple[delta: int64, dirFrom, lon,
      lat: float64]] = initTable[string, tuple[delta: int64, dirFrom, lon,
      lat: float64]]()
  for f in dfeats:
    let p = f{"properties"}
    if p == nil: continue
    if not acceptValue(p{"value"}): continue
    let sidNode = p{"stationId"}
    let obsNode = p{"observed"}
    if sidNode == nil or obsNode == nil: continue
    let sid = sidNode.getStr()
    let coords = f{"geometry"}{"coordinates"}
    if coords == nil or coords.len < 2: continue
    let lon = coords[0].getFloat()
    let lat = coords[1].getFloat()
    let obsStr = obsNode.getStr()
    let t = parseIsoUtc(obsStr)
    let delta = abs((t - scanDt).inSeconds)
    if sid notin dirBest or delta < dirBest[sid].delta:
      dirBest[sid] = (delta, p{"value"}.getFloat(), lon, lat)

  for sid, d in dirBest:
    if sid in spdBy:
      result.add((d.lon, d.lat, d.dirFrom, spdBy[sid].speed))

type
  WindArrow* = tuple[lon, lat, dirFrom, speed: float64]

proc assignWindToSites*(stations: seq[WindStation], sites: openArray[
    WindSite]): seq[WindArrow] =
  if stations.len == 0 or sites.len == 0:
    return @[]
  for site in sites:
    var
      sinSum = 0.0
      cosSum = 0.0
      spdSum = 0.0
      n = 0
    for st in stations:
      let (_, _, dist) = vincentyInverse(site.lon, site.lat, st.lon, st.lat)
      if dist <= MaxStationRadiusKm * 1000.0:
        let dRad = degToRad(st.dirFrom)
        sinSum += sin(dRad)
        cosSum += cos(dRad)
        spdSum += st.speed
        inc n
    if n == 0:
      continue
    let meanDir = (radToDeg(arctan2(sinSum / float(n), cosSum / float(n))) +
        360.0) mod 360.0
    let meanSpd = spdSum / float(n)
    result.add((site.lon, site.lat, meanDir, meanSpd))

# --- Arrow geometry (in projection metres) ---

type
  ArrowGeom = seq[tuple[x, y: float64]] # 7-vertex polygon in projection metres

proc arrowEndpoints*(proj: Projection, arrows: seq[WindArrow],
                     lengthM = ArrowLengthM): tuple[x0, y0, x1, y1, fx, fy: seq[float64]] =
  let n = arrows.len
  result.x0 = newSeq[float64](n)
  result.y0 = newSeq[float64](n)
  result.x1 = newSeq[float64](n)
  result.y1 = newSeq[float64](n)
  result.fx = newSeq[float64](n)
  result.fy = newSeq[float64](n)
  for i, a in arrows:
    # "To" azimuth (direction wind blows TO) = dirFrom + 180.
    let toAz = (a.dirFrom + 180.0) mod 360.0
    let (dlon, dlat) = vincentyForward(a.lon, a.lat, toAz, 1000.0)
    let (px0, py0) = proj.forward(a.lat, a.lon)
    let (px1, py1) = proj.forward(dlat, dlon)
    let ux = px1 - px0
    let uy = py1 - py0
    let mag = sqrt(ux * ux + uy * uy)
    let fx = if mag > 0: ux / mag else: 0.0
    let fy = if mag > 0: uy / mag else: 0.0
    let half = lengthM / 2.0
    result.x0[i] = px0 - fx * half
    result.y0[i] = py0 - fy * half
    result.x1[i] = px0 + fx * half
    result.y1[i] = py0 + fy * half
    result.fx[i] = fx
    result.fy[i] = fy

proc arrowPolygons*(x0, y0, x1, y1, fx, fy: seq[float64]): seq[ArrowGeom] =
  const
    ArrowShaftHalfWidthM = 7200.0 # shaft half-width
    ArrowHeadLenM = 31500.0       # head length (77% of the 41 km arrow)
    ArrowHeadHalfWidthM = 14000.0 # head half-width
  for i in 0 ..< x0.len:
    let dx = fx[i]
    let dy = fy[i]
    let px = -dy
    let py = dx
    let sx = x0[i]
    let sy = y0[i]
    let ex = x1[i]
    let ey = y1[i]
    let jx = ex - dx * ArrowHeadLenM
    let jy = ey - dy * ArrowHeadLenM
    let verts = @[
      (sx + px * ArrowShaftHalfWidthM, sy + py * ArrowShaftHalfWidthM),
      (sx - px * ArrowShaftHalfWidthM, sy - py * ArrowShaftHalfWidthM),
      (jx - px * ArrowShaftHalfWidthM, jy - py * ArrowShaftHalfWidthM),
      (jx - px * ArrowHeadHalfWidthM, jy - py * ArrowHeadHalfWidthM),
      (ex, ey),
      (jx + px * ArrowHeadHalfWidthM, jy + py * ArrowHeadHalfWidthM),
      (jx + px * ArrowShaftHalfWidthM, jy + py * ArrowShaftHalfWidthM),
    ]
    result.add(verts)

# --- Wind cache JSON ---

proc saveWindCache*(path: string, stations: seq[WindStation]) =
  var arr = newJArray()
  for st in stations:
    var row = newJArray()
    row.add(newJFloat(st.lon))
    row.add(newJFloat(st.lat))
    row.add(newJFloat(st.dirFrom))
    row.add(newJFloat(st.speed))
    arr.add(row)
  writeFile(path, $arr)

proc loadWindCache*(path: string): seq[WindStation] =
  let data = parseFile(path)
  for row in data:
    result.add((row[0].getFloat(), row[1].getFloat(),
                row[2].getFloat(), row[3].getFloat()))
