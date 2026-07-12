import std/[strutils, strformat, times, math, tables, json]
import geo, config, httputil

type
  WindStation* = tuple[lon, lat, dirFrom, speed: float64]

proc fetchWindAt*(scanDt: Time, windowMinutes = 10): seq[WindStation] =
  let lo = scanDt - initDuration(minutes = windowMinutes)
  let hi = scanDt + initDuration(minutes = windowMinutes)
  let loStr = lo.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let hiStr = hi.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let dtRange = loStr & "/" & hiStr

  proc fetch(param: string): JsonNode =
    let url = &"{DmiMetObsApi}/collections/observation/items?parameterId={param}&datetime={dtRange}&bbox={WindBbox}&limit=300000"
    httpGetJson(url){"features"}

  let dfeats = fetch("wind_dir")
  let sfeats = fetch("wind_speed")
  if dfeats == nil or sfeats == nil or dfeats.len == 0 or sfeats.len == 0:
    return @[]

  # Speed: nearest observation per station.
  var spdBy: Table[string, tuple[delta: int64, speed: float64]] = initTable[string, tuple[delta: int64, speed: float64]]()
  for f in sfeats:
    let p = f{"properties"}
    if p == nil: continue
    let v = p{"value"}
    if v == nil or v.kind != JFloat: continue
    let sid = p["stationId"].getStr()
    let obsStr = p["observed"].getStr().replace("Z", "+00:00")
    let t = parse(obsStr, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
    let delta = abs((t.toTime() - scanDt).inSeconds)
    if sid notin spdBy or delta < spdBy[sid].delta:
      spdBy[sid] = (delta, v.getFloat())

  # Direction: nearest observation per station.
  var dirBest: Table[string, tuple[delta: int64, dirFrom, lon, lat: float64]] = initTable[string, tuple[delta: int64, dirFrom, lon, lat: float64]]()
  for f in dfeats:
    let p = f{"properties"}
    if p == nil: continue
    let v = p{"value"}
    if v == nil or v.kind != JFloat: continue
    let sid = p["stationId"].getStr()
    let coords = f{"geometry"}{"coordinates"}
    if coords == nil or coords.len < 2: continue
    let lon = coords[0].getFloat()
    let lat = coords[1].getFloat()
    let obsStr = p["observed"].getStr().replace("Z", "+00:00")
    let t = parse(obsStr, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
    let delta = abs((t.toTime() - scanDt).inSeconds)
    if sid notin dirBest or delta < dirBest[sid].delta:
      dirBest[sid] = (delta, v.getFloat(), lon, lat)

  for sid, d in dirBest:
    if sid in spdBy:
      result.add((d.lon, d.lat, d.dirFrom, spdBy[sid].speed))

type
  WindArrow* = tuple[lon, lat, dirFrom, speed: float64]

proc assignWindToSites*(stations: seq[WindStation], sites: openArray[WindSite]): seq[WindArrow] =
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
    let meanDir = (radToDeg(arctan2(sinSum / float(n), cosSum / float(n))) + 360.0) mod 360.0
    let meanSpd = spdSum / float(n)
    result.add((site.lon, site.lat, meanDir, meanSpd))

# --- Arrow geometry (in projection metres) ---

type
  ArrowGeom* = seq[tuple[x, y: float64]]  # 7-vertex polygon in projection metres

proc arrowEndpoints*(proj: Projection, arrows: seq[WindArrow],
                     lengthM = 41000.0): tuple[x0, y0, x1, y1, fx, fy: seq[float64]] =
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

proc arrowPolygons*(x0, y0, x1, y1, fx, fy: seq[float64],
                    lengthM = 41000.0, headSize = 35.0,
                    shaftWidth = 8.0): seq[ArrowGeom] =
  const
    ShaftHalfM = 8.0 * 900.0
    HeadLenM = 35.0 * 900.0
    HeadWidM = 35.0 * 400.0
  for i in 0 ..< x0.len:
    let dx = fx[i]
    let dy = fy[i]
    let px = -dy
    let py = dx
    let sx = x0[i]
    let sy = y0[i]
    let ex = x1[i]
    let ey = y1[i]
    let jx = ex - dx * HeadLenM
    let jy = ey - dy * HeadLenM
    let verts = @[
      (sx + px * ShaftHalfM, sy + py * ShaftHalfM),
      (sx - px * ShaftHalfM, sy - py * ShaftHalfM),
      (jx - px * ShaftHalfM, jy - py * ShaftHalfM),
      (jx - px * HeadWidM, jy - py * HeadWidM),
      (ex, ey),
      (jx + px * HeadWidM, jy + py * HeadWidM),
      (jx + px * ShaftHalfM, jy + py * ShaftHalfM),
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
