import std/[math]
import arraymancer
import geo, config, h5read

proc bilinearSample*(t: Tensor[float32], xIn, yIn: seq[float64],
                     x, y: float64; j0, i0: var int): float32 =
  # Nearest-neighbor clamping to valid range.
  # `j0`/`i0` are hints seeded by the caller and advanced in place so the
  # bracketing search is O(1) amortized across consecutive (monotonic) samples.
  let
    nx = xIn.len
    ny = yIn.len
  if nx < 2 or ny < 2:
    return NaN.float32
  # Reject points outside the grid domain. Without this the bracket search
  # clamps to the edge cell and tx/ty clamp to [0,1], extrapolating edge
  # values instead of signalling no-data.
  if x < xIn[0] or x > xIn[^1] or y < yIn[0] or y > yIn[^1]:
    return NaN.float32
  # Column index: bracket x starting from the hint.
  while j0 < nx - 2 and xIn[j0 + 1] <= x: inc j0
  while j0 > 0 and xIn[j0] > x: dec j0
  let j1 = j0 + 1
  let tx = clamp((x - xIn[j0]) / (xIn[j1] - xIn[j0]), 0.0, 1.0)
  # Row index: bracket y starting from the hint.
  while i0 < ny - 2 and yIn[i0 + 1] <= y: inc i0
  while i0 > 0 and yIn[i0] > y: dec i0
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
  # Add margin.
  let dx = xmax - xmin
  let dy = ymax - ymin
  xmin -= dx * CompositeMargin
  xmax += dx * CompositeMargin
  ymin -= dy * CompositeMargin
  ymax += dy * CompositeMargin

  let nx = CompositeGridNx
  let aspect = (ymax - ymin) / (xmax - xmin)
  let ny = max(2, int(round(nx.float64 * aspect)))

  # Output grid: row 0 = north (ymax), descending y.
  var grid = newTensorWith[float32]([ny, nx], NaN.float32)

  for st in stations:
    for iy in 0 ..< ny:
      let yOut = ymax - (ymax - ymin) * float64(iy) / float64(ny - 1)
      # Running indices: reset per row; advanced in place by bilinearSample
      # as xOut increases monotonically across the row.
      var
        j0 = 0
        i0 = 0
      for ix in 0 ..< nx:
        let xOut = xmin + (xmax - xmin) * float64(ix) / float64(nx - 1)
        # Output stereographic -> lat/lon -> station gnomonic.
        let (lat, lon) = outProj.inverse(xOut, yOut)
        let (sx, sy) = st.stationProj.forward(lat, lon)
        let v = bilinearSample(st.dbz, st.xIn, st.yIn, sx, sy, j0, i0)
        if not v.isNaN:
          let cur = grid[iy, ix]
          if cur.isNaN or v > cur:
            grid[iy, ix] = v

  result = RadarField(
    dbz: grid,
    extent: (xmin, xmax, ymin, ymax),
    proj: outProj,
  )
