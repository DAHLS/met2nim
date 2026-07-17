import unittest
import arraymancer
import interp

suite "interp: bilinearSample":

  test "linear grid interpolation":
    # 3x3 grid, value = i + j (grid-row + grid-col). Sample at the centre.
    var t = newTensor[float32]([3, 3])
    for i in 0 .. 2:
      for j in 0 .. 2:
        t[i, j] = float32(i + j)
    let xIn = @[0.0, 1.0, 2.0]
    let yIn = @[0.0, 1.0, 2.0]
    var j0 = 0
    var i0 = 0
    let v = bilinearSample(t, xIn, yIn, 1.5, 1.5, j0, i0)
    check abs(v - 3.0f) <= 1e-3f

  test "NaN propagation":
    var t = newTensor[float32]([2, 2])
    t[0, 0] = 1; t[0, 1] = 2; t[1, 0] = 3; t[1, 1] = NaN
    let xIn = @[0.0, 1.0]
    let yIn = @[0.0, 1.0]
    var j0 = 0
    var i0 = 0
    let v = bilinearSample(t, xIn, yIn, 0.5, 0.5, j0, i0)
    check v != v # NaN (no echo at this point)

  test "out-of-domain sample returns NaN (no edge extrapolation)":
    var t = newTensor[float32]([2, 2])
    t[0, 0] = 1; t[0, 1] = 2; t[1, 0] = 3; t[1, 1] = 4
    let xIn = @[0.0, 1.0]
    let yIn = @[0.0, 1.0]
    for (x, y) in [(-0.5, 0.5), (1.5, 0.5), (0.5, -0.5), (0.5, 1.5)]:
      var j0 = 0
      var i0 = 0
      let v = bilinearSample(t, xIn, yIn, x, y, j0, i0)
      check v != v # NaN: must not return an edge value

  test "running-index hint is result-invariant (#10)":
    # The seeded j0/i0 hints must not change the computed value, only the
    # speed of the bracket search. Guards the per-row running-index change.
    var t = newTensor[float32]([5, 5])
    for i in 0 .. 4:
      for j in 0 .. 4:
        t[i, j] = float32(i * 5 + j)
    let xIn = @[0.0, 1.0, 2.0, 3.0, 4.0]
    let yIn = @[0.0, 1.0, 2.0, 3.0, 4.0]
    # NaN-aware equality: out-of-domain samples return NaN for any hint.
    proc sameNan(a, b: float32): bool =
      (a == b) or (a != a and b != b)
    for sx in 0 .. 4:
      for sy in 0 .. 4:
        let x = float64(sx) + 0.3
        let y = float64(sy) + 0.7
        var j0f = 0
        var i0f = 0
        let fresh = bilinearSample(t, xIn, yIn, x, y, j0f, i0f)
        var j0h = 2 # arbitrary non-zero seed
        var i0h = 3
        let hinted = bilinearSample(t, xIn, yIn, x, y, j0h, i0h)
        check sameNan(fresh, hinted)
