import std/[json, strutils]
import pixie
import geo, config

type
  Coastline* = seq[tuple[x, y: float64]]  # in lat/lon

proc loadCoastlines*(jsonStr: string): seq[Coastline] =
  let data = parseJson(jsonStr)
  let feats = data["features"]
  for f in feats:
    let geom = f["geometry"]
    let gtype = geom["type"].getStr()
    if gtype == "LineString":
      let coords = geom["coordinates"]
      var line: Coastline = @[]
      for c in coords:
        let lon = c[0].getFloat()
        let lat = c[1].getFloat()
        line.add((lon, lat))
      result.add(line)
    elif gtype == "MultiLineString":
      let lines = geom["coordinates"]
      for lineCoords in lines:
        var line: Coastline = @[]
        for c in lineCoords:
          let lon = c[0].getFloat()
          let lat = c[1].getFloat()
          line.add((lon, lat))
        result.add(line)

proc drawCoastlines*(ctx: Context, lines: seq[Coastline], proj: Projection,
                     viewExt: Extent, canvasW, canvasH: int) =
  # Transform: projection metres -> canvas pixels.
  # x_px = (x - xmin) / (xmax - xmin) * canvasW
  # y_px = (ymax - y) / (ymax - ymin) * canvasH   [row 0 = north]
  let dx = viewExt[1] - viewExt[0]
  let dy = viewExt[3] - viewExt[2]
  if dx <= 0 or dy <= 0:
    return
  ctx.strokeStyle = parseHex(CoastColorHex.strip(chars = {'#'}))
  ctx.lineWidth = 1.5
  for line in lines:
    if line.len < 2:
      continue
    ctx.beginPath()
    var added = 0
    for pt in line:
      let (px, py) = proj.forward(pt[1], pt[0])
      let cx = float32((px - viewExt[0]) / dx * float64(canvasW))
      let cy = float32((viewExt[3] - py) / dy * float64(canvasH))
      if added == 0:
        ctx.moveTo(cx, cy)
      else:
        ctx.lineTo(cx, cy)
      inc added
    if added >= 2:
      ctx.stroke()
