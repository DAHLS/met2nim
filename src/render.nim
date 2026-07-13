import std/[math, strformat, os, algorithm]
import pixie
import arraymancer
import geo, config, h5read, wind, coast

const embeddedFontBytes* = staticRead("../fonts/DejaVuSans-Bold.ttf")

proc loadWindFont*(overridePath: string): Font =
  ## Returns the embedded DejaVuSans-Bold font, or a user-supplied font
  ## via --font. On a bad override path, warns and falls back to embedded.
  result =
    if overridePath.len > 0:
      try: readFont(overridePath)
      except CatchableError:
        stderr.writeLine("warning: --font load failed ('" & overridePath & "'); using embedded font")
        newFont(parseTtf(embeddedFontBytes))
    else:
      newFont(parseTtf(embeddedFontBytes))
  result.size = 22.0

proc cleanRadar*(dbz: Tensor[float32], minDbz: float32,
                 despeckle: bool): Tensor[float32] =
  result = dbz.map(proc(x: float32): float32 =
    if x != x or x < minDbz: NaN.float32 else: x)
  if not despeckle:
    return
  # 3x3 median filter: a pixel survives only if the median of its
  # 3x3 neighborhood (with NaN treated as minDbz-1) is above threshold.
  let
    rows = dbz.shape.data[0]
    cols = dbz.shape.data[1]
  var med = newTensorWith[float32]([rows, cols], NaN.float32)
  for i in 0 ..< rows:
    for j in 0 ..< cols:
      var vals: array[9, float32]
      var n = 0
      for di in -1 .. 1:
        for dj in -1 .. 1:
          let ni = min(max(i + di, 0), rows - 1)
          let nj = min(max(j + dj, 0), cols - 1)
          let v = result[ni, nj]
          if v != v:
            vals[n] = minDbz - 1.0
          else:
            vals[n] = v
          inc n
      # Simple sort-based median of 9 values.
      vals.sort()
      let m = vals[4]  # median of 9
      if m >= minDbz:
        med[i, j] = result[i, j]
  result = med

type
  RenderArgs* = object
    useSatellite*: bool
    useWind*: bool
    zoom*: float64
    minDbz*: float32
    despeckle*: bool
    satImage*: Image        # satellite background (nil if none)
    satBbox*: tuple[w, s, e, n: float64]  # geographic bbox of sat image
    coastlines*: seq[Coastline]
    windArrows*: seq[WindArrow]
    windFont*: Font

proc projToCanvas*(viewExt: Extent, x, y: float64,
                   canvasW, canvasH: int): tuple[px, py: float32] =
  let dx = viewExt[1] - viewExt[0]
  let dy = viewExt[3] - viewExt[2]
  result.px = float32((x - viewExt[0]) / dx * float64(canvasW))
  result.py = float32((viewExt[3] - y) / dy * float64(canvasH))

proc canvasToProj*(viewExt: Extent, px, py: float32,
                   canvasW, canvasH: int): tuple[x, y: float64] =
  let dx = viewExt[1] - viewExt[0]
  let dy = viewExt[3] - viewExt[2]
  result.x = viewExt[0] + float64(px) / float64(canvasW) * dx
  result.y = viewExt[3] - float64(py) / float64(canvasH) * dy

proc renderRadarOverlay*(canvas: Image, rf: RadarField, viewExt: Extent,
                         minDbz: float32, despeckle: bool) =
  let dbz = cleanRadar(rf.dbz, minDbz, despeckle)
  let rows = dbz.shape.data[0]
  let cols = dbz.shape.data[1]
  let rExt = rf.extent
  let rDx = rExt[1] - rExt[0]
  let rDy = rExt[3] - rExt[2]
  if rDx <= 0 or rDy <= 0:
    return
  let
    vDx = viewExt[1] - viewExt[0]
    vDy = viewExt[3] - viewExt[2]
    cw = canvas.width
    ch = canvas.height
  # For each canvas pixel, map to radar grid and sample (nearest neighbor).
  for py in 0 ..< ch:
    let vY = viewExt[3] - (float64(py) + 0.5) / float64(ch) * vDy
    let rRowF = (rExt[3] - vY) / rDy * float64(rows - 1)
    let rRow = if rRowF < 0 or rRowF > float64(rows - 1) + 0.5: -1
              elif rRowF >= float64(rows - 1): rows - 1
              else: int(rRowF + 0.5)
    if rRow < 0:
      continue
    for px in 0 ..< cw:
      let vX = viewExt[0] + (float64(px) + 0.5) / float64(cw) * vDx
      let rColF = (vX - rExt[0]) / rDx * float64(cols - 1)
      let rCol = if rColF < 0 or rColF > float64(cols - 1) + 0.5: -1
                elif rColF >= float64(cols - 1): cols - 1
                else: int(rColF + 0.5)
      if rCol < 0:
        continue
      let v = dbz[rRow, rCol]
      if v != v:
        continue
      let c = dbzToRgba(v)
      if c[3] <= 0.0:
        continue
      let r = uint8(c[0] * 255.0 + 0.5)
      let g = uint8(c[1] * 255.0 + 0.5)
      let b = uint8(c[2] * 255.0 + 0.5)
      let a = uint8(c[3] * 255.0 + 0.5)
      let dest = canvas[px, py]
      # Alpha blend: src over dest.
      let af = float(a) / 255.0
      let dr = uint8(float(dest.r) * (1.0 - af) + float(r) * af + 0.5)
      let dg = uint8(float(dest.g) * (1.0 - af) + float(g) * af + 0.5)
      let db = uint8(float(dest.b) * (1.0 - af) + float(b) * af + 0.5)
      canvas[px, py] = rgba(dr, dg, db, 255)

proc renderSatelliteBackground*(canvas: Image, satImg: Image,
                                satBbox: tuple[w, s, e, n: float64],
                                proj: Projection, viewExt: Extent) =
  let
    cw = canvas.width
    ch = canvas.height
    vDx = viewExt[1] - viewExt[0]
    vDy = viewExt[3] - viewExt[2]
    sDx = satBbox.e - satBbox.w
    sDy = satBbox.n - satBbox.s
  if sDx <= 0 or sDy <= 0:
    return
  let
    sW = satImg.width
    sH = satImg.height
  # Precompute lat/lon for every canvas pixel in one inverse-projection pass.
  # Keeps the expensive (trig-heavy) projection out of the hot sample loop.
  var latGrid = newSeq[float64](cw * ch)
  var lonGrid = newSeq[float64](cw * ch)
  for py in 0 ..< ch:
    let vY = viewExt[3] - (float64(py) + 0.5) / float64(ch) * vDy
    for px in 0 ..< cw:
      let vX = viewExt[0] + (float64(px) + 0.5) / float64(cw) * vDx
      let (lat, lon) = proj.inverse(vX, vY)
      latGrid[py * cw + px] = lat
      lonGrid[py * cw + px] = lon
  # Second pass: sample the satellite image with the precomputed coords.
  for py in 0 ..< ch:
    for px in 0 ..< cw:
      let lat = latGrid[py * cw + px]
      let lon = lonGrid[py * cw + px]
      if lon < satBbox.w or lon > satBbox.e or
         lat < satBbox.s or lat > satBbox.n:
        continue
      let sCol = int((lon - satBbox.w) / sDx * float64(sW - 1) + 0.5)
      let sRow = int((satBbox.n - lat) / sDy * float64(sH - 1) + 0.5)
      if sCol < 0 or sCol >= sW or sRow < 0 or sRow >= sH:
        continue
      let src = satImg[sCol, sRow]
      if src.a == 0:
        continue
      let dest = canvas[px, py]
      let af = float(src.a) / 255.0
      let dr = uint8(float(dest.r) * (1.0 - af) + float(src.r) * af + 0.5)
      let dg = uint8(float(dest.g) * (1.0 - af) + float(src.g) * af + 0.5)
      let db = uint8(float(dest.b) * (1.0 - af) + float(src.b) * af + 0.5)
      canvas[px, py] = rgba(dr, dg, db, 255)

proc renderWindArrows*(ctx: contexts.Context, proj: Projection, viewExt: Extent,
                       arrows: seq[WindArrow], windFont: Font) =
  if arrows.len == 0:
    return
  let (x0, y0, x1, y1, fx, fy) = arrowEndpoints(proj, arrows)
  let polys = arrowPolygons(x0, y0, x1, y1, fx, fy)
  let
    cw = ctx.image.width.float32
    ch = ctx.image.height.float32
    vDx = float32(viewExt[1] - viewExt[0])
    vDy = float32(viewExt[3] - viewExt[2])
  # Fill arrows.
  ctx.fillStyle = color(ArrowColorR, ArrowColorG, ArrowColorB, ArrowColorA)
  for i, poly in polys:
    ctx.beginPath()
    var started = false
    for v in poly:
      let px = float32((v[0] - viewExt[0]) / float64(vDx) * float64(cw))
      let py = float32((viewExt[3] - v[1]) / float64(vDy) * float64(ch))
      if not started:
        ctx.moveTo(px, py)
        started = true
      else:
        ctx.lineTo(px, py)
    if started:
      ctx.closePath()
      ctx.fill()
  # Speed labels: bold black text with white outline on each arrow.
  # Both stroke and fill use the same typeset arrangement, so they align
  # automatically (no manual baseline offset needed).
  for i, a in arrows:
    let mx = (x0[i] + x1[i]) / 2.0
    let my = (y0[i] + y1[i]) / 2.0
    let px = float32((mx - viewExt[0]) / float64(vDx) * float64(cw))
    let py = float32((viewExt[3] - my) / float64(vDy) * float64(ch))
    let label = $int(a.speed)
    let t = translate(vec2(px, py))
    # White stroke (outline) drawn first.
    windFont.paint = rgba(255, 255, 255, 255)
    ctx.image.strokeText(windFont, label, t,
      strokeWidth = 3.0, hAlign = CenterAlign, vAlign = MiddleAlign)
    # Black fill on top.
    windFont.paint = rgba(0, 0, 0, 255)
    ctx.image.fillText(windFont, label, t,
      hAlign = CenterAlign, vAlign = MiddleAlign)

proc renderImage*(rf: RadarField, scanDt: string, args: RenderArgs): Image =
  let proj = rf.proj
  let viewExt = proj.viewExtent(args.zoom)
  let canvas = newImage(CanvasW, CanvasH)
  canvas.fill(rgba(0, 0, 0, 255))

  # 1. Satellite background.
  if args.useSatellite and not args.satImage.isNil:
    renderSatelliteBackground(canvas, args.satImage, args.satBbox, proj, viewExt)

  # 2. Radar overlay.
  renderRadarOverlay(canvas, rf, viewExt, args.minDbz, args.despeckle)

  # 3. Coastlines.
  if args.coastlines.len > 0:
    let ctx = newContext(canvas)
    drawCoastlines(ctx, args.coastlines, proj, viewExt, CanvasW, CanvasH)

  # 4. Wind arrows.
  if args.useWind and args.windArrows.len > 0:
    let ctx = newContext(canvas)
    renderWindArrows(ctx, proj, viewExt, args.windArrows, args.windFont)
    echo &"plotted {args.windArrows.len} wind arrows"

  result = canvas

proc saveImage*(img: Image, outDir, scanStamp: string) =
  discard existsOrCreateDir(outDir)
  let outName = "radar_" & scanStamp & ".png"
  let outPath = outDir / outName
  img.writeFile(outPath)
  echo "Saved: " & outPath
