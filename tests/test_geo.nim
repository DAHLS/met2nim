import unittest
import std/[math]
import geo, config

suite "geo: projections":

  test "forward/inverse round-trip":
    let p = dkCompositeProjection()
    for (lat, lon) in [(55.0, 11.0), (56.0, 10.0), (60.0, 20.0),
                       (50.0, 8.0), (0.0, 0.0), (45.0, -100.0)]:
      let (x, y) = p.forward(lat, lon)
      let (lat2, lon2) = p.inverse(x, y)
      check abs(lat2 - lat) <= 1e-6
      check abs(lon2 - lon) <= 1e-6

  test "conformalLat / geodeticFromConformal round-trip":
    for phiDeg in [10.0, 45.0, 56.0, 70.0]:
      let phi = degToRad(phiDeg)
      check abs(geodeticFromConformal(conformalLat(phi)) - phi) <= 1e-9

  test "dkCompositeProjection":
    let p = dkCompositeProjection()
    check p.kind == pkStere
    check abs(p.lat0 - 56.0) <= 1e-9
    check abs(p.lon0 - 10.5666) <= 1e-9

  test "parseProjdef stere/gnom + unsupported raises":
    let s = parseProjdef("+proj=stere +lat_0=56 +lon_0=10.5666 +lat_ts=56 +ellps=WGS84")
    check s.kind == pkStere
    check abs(s.lat0 - 56.0) <= 1e-9
    check abs(s.lon0 - 10.5666) <= 1e-9
    let g = parseProjdef("+proj=gnom +lat_0=56 +lon_0=10.5")
    check g.kind == pkGnom
    expect ValueError:
      discard parseProjdef("+proj=foobar")

  test "viewExtent size and centering":
    let p = dkCompositeProjection()
    let ext = p.viewExtent(1.0)
    let w = ext[1] - ext[0]
    let h = ext[3] - ext[2]
    check abs(w - BaseWidthM) <= 1.0
    check abs(h - BaseWidthM * 3.0 / 4.0) <= 1.0
    let (cx, cy) = p.forward(CenterLat, CenterLon)
    check abs((ext[0] + ext[1]) / 2.0 - cx) <= 1e-6
    check abs((ext[2] + ext[3]) / 2.0 - cy) <= 1e-6

suite "geo: Vincenty geodesics":

  test "inverse Cambridge -> Paris (canonical example)":
    # Wikipedia Vincenty worked example.
    let (az, baz, dist) = vincentyInverse(0.119, 52.205, 2.351, 48.857)
    check abs(dist - 404_300.0) <= 500.0
    check abs(az - 156.2) <= 1.0

  test "forward/inverse round-trip":
    let (dlon, dlat) = vincentyForward(10.0, 56.0, 123.0, 12345.0)
    let (az, baz, dist) = vincentyInverse(10.0, 56.0, dlon, dlat)
    check abs(dist - 12345.0) <= 1e-3
    check abs(az - 123.0) <= 1e-3
