import unittest
import std/[math]
import geo, config, wind

suite "wind: site assignment":

  test "circular-mean direction of two stations":
    let site = (10.0, 56.0)                  # (lon, lat)
    let stations = @[(10.0, 56.0, 10.0, 5.0), (10.0, 56.0, 30.0, 5.0)]
    let arrows = assignWindToSites(stations, [site])
    check arrows.len == 1
    check abs(arrows[0].dirFrom - 20.0) <= 0.5
    check abs(arrows[0].speed - 5.0) <= 1e-6

  test "station outside radius is excluded":
    let site = (10.0, 56.0)
    # ~10 deg of longitude away at this latitude is far beyond the 75 km cutoff.
    let stations = @[(20.0, 56.0, 0.0, 5.0)]
    let arrows = assignWindToSites(stations, [site])
    check arrows.len == 0

suite "wind: arrow geometry":

  test "endpoint separation equals lengthM":
    let proj = dkCompositeProjection()
    let arrows = @[(10.0, 56.0, 0.0, 10.0)]  # (lon, lat, dirFrom, speed)
    let (x0, y0, x1, y1, fx, fy) = arrowEndpoints(proj, arrows, 41000.0)
    let dx = x1[0] - x0[0]
    let dy = y1[0] - y0[0]
    let dist = sqrt(dx * dx + dy * dy)
    check abs(dist - 41000.0) <= 1e-6
