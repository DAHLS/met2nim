import std/[math]
import arraymancer
import geo, h5read

proc bilinearSample(t: Tensor[float32], xIn, yIn: seq[float64],
                    x, y: float64): float32 =
  # Nearest-neighbor clamping to valid range.
  let nx = xIn.len
  let ny = yIn.len
  if nx < 2 or ny < 2:
    return NaN.float32
  # Find column index.
  var j0 = 0
  if x <= xIn[0]:
    j0 = 0
  elif x >= xIn[nx - 1]:
    j0 = nx - 2
  else:
    while j0 < nx - 2 and xIn[j0 + 1] < x:
      inc j0
  let j1 = j0 + 1
  let tx = clamp((x - xIn[j0]) / (xIn[j1] - xIn[j0]), 0.0, 1.0)
  # Find row index.
  var i0 = 0
  if y <= yIn[0]:
    i0 = 0
  elif y >= yIn[ny - 1]:
    i0 = ny - 2
  else:
    while i0 < ny - 2 and yIn[i0 + 1] < y:
      inc i0
  let i1 = i0 + 1
  let ty = clamp((y - yIn[i0]) / (yIn[i1] - yIn[i0]), 0.0, 1.0)
  # Bilinear interpolation.
  let v00 = t[i0, j0]
  let v01 = t[i0, j1]
  let v10 = t[i1, j0]
  let v11 = t[i1, j1]
  # If any neighbor is NaN, return NaN (no echo at this point).
  if v00.isNaN or v01.isNaN or v10.isNaN or v11.isNaN:
    return NaN.float32
  let r0 = v00 * float32(1.0 - tx) + v01 * float32(tx)
  let r1 = v10 * float32(1.0 - tx) + v11 * float32(tx)
  result = r0 * float32(1.0 - ty) + r1 * float32(ty)

proc compositePseudoCappi*(stations: seq[PseudoCappiStation],
                           outProj: Projection): RadarField =
  # Compute the union extent from all stations' corner coordinates.
  # We need to re-derive corners from each station's xIn/yIn ranges
  # (which are in station projection). Convert station-proj corners
  # back to lat/lon, then to output-proj to find the union bbox.
  var
    xmin = Inf
    xmax = -Inf
    ymin = Inf
    ymax = -Inf
  for st in stations:
    let sx0 = st.xIn[0]
    let sx1 = st.xIn[^1]
    let sy0 = st.yIn[0]
    let sy1 = st.yIn[^1]
    # Station-proj corners -> lat/lon -> output proj.
    for (sx, sy) in [(sx0, sy0), (sx1, sy0), (sx0, sy1), (sx1, sy1)]:
      let (lat, lon) = st.stationProj.inverse(sx, sy)
      let (ox, oy) = outProj.forward(lat, lon)
      xmin = min(xmin, ox)
      xmax = max(xmax, ox)
      ymin = min(ymin, oy)
      ymax = max(ymax, oy)
  # Add 2% margin.
  let dx = xmax - xmin
  let dy = ymax - ymin
  let margin = 0.02
  xmin -= dx * margin
  xmax += dx * margin
  ymin -= dy * margin
  ymax += dy * margin

  let nx = 1200
  let aspect = (ymax - ymin) / (xmax - xmin)
  let ny = max(2, int(round(nx.float64 * aspect)))

  # Output grid: row 0 = north (ymax), descending y.
  var grid = newTensorWith[float32]([ny, nx], NaN.float32)

  for st in stations:
    for iy in 0 ..< ny:
      let yOut = ymax - (ymax - ymin) * float64(iy) / float64(ny - 1)
      for ix in 0 ..< nx:
        let xOut = xmin + (xmax - xmin) * float64(ix) / float64(nx - 1)
        # Output stereographic -> lat/lon -> station gnomonic.
        let (lat, lon) = outProj.inverse(xOut, yOut)
        let (sx, sy) = st.stationProj.forward(lat, lon)
        let v = bilinearSample(st.dbz, st.xIn, st.yIn, sx, sy)
        if not v.isNaN:
          let cur = grid[iy, ix]
          if cur.isNaN or v > cur:
            grid[iy, ix] = v

  result = RadarField(
    dbz: grid,
    extent: (xmin, xmax, ymin, ymax),
    proj: outProj,
  )
