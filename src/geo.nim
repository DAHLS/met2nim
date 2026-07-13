import std/[math, strutils, tables]
import config

const
  Wgs84A* = 6378137.0           # semi-major axis
  Wgs84F* = 1.0 / 298.257223563 # flattening
  Wgs84B* = Wgs84A * (1.0 - Wgs84F)
  Wgs84E2* = 2.0 * Wgs84F - Wgs84F * Wgs84F # eccentricity squared
  Wgs84E* = sqrt(Wgs84E2)

type
  ProjectionKind* = enum
    pkStere, pkGnom

  Projection* = object
    kind*: ProjectionKind
    lat0*, lon0*: float64       # center in degrees
    latTs*: float64             # true scale latitude (stere), degrees
    phi0Rad*, lam0Rad*: float64 # center in radians
    chi0Rad*: float64           # conformal latitude of center (stere), radians
    R*: float64                 # sphere radius (= Wgs84A)

  Extent* = tuple[xmin, xmax, ymin, ymax: float64]

proc conformalLat*(phi: float64): float64 =
  let s = sin(phi)
  let t = tan(PI / 4.0 + phi / 2.0)
  let psi = ln(t) - (Wgs84E / 2.0) * ln((1.0 + Wgs84E * s) / (1.0 - Wgs84E * s))
  result = 2.0 * arctan(exp(psi)) - PI / 2.0

proc geodeticFromConformal*(chi: float64): float64 =
  # Series expansion: phi = chi + A1 sin(2chi) + A2 sin(4chi) + ...
  let e2 = Wgs84E2
  let e4 = e2 * e2
  let e6 = e4 * e2
  let e8 = e4 * e4
  let a1 = e2 / 2.0 + 5.0 * e4 / 24.0 + e6 / 12.0 + 13.0 * e8 / 360.0
  let a2 = 7.0 * e4 / 48.0 + 29.0 * e6 / 240.0 + 811.0 * e8 / 11520.0
  let a3 = 7.0 * e6 / 120.0 + 81.0 * e8 / 1120.0
  let a4 = 4279.0 * e8 / 161280.0
  result = chi + a1 * sin(2.0 * chi) + a2 * sin(4.0 * chi) +
           a3 * sin(6.0 * chi) + a4 * sin(8.0 * chi)

proc parseProjdef*(projdef: string): Projection =
  var parts: Table[string, string] = initTable[string, string]()
  let clean = projdef.strip(leading = true, trailing = true, chars = {'\0', ' ', '\t', '\r', '\n'})
  for tok in clean.split():
    if tok.startsWith("+"):
      let s = tok[1 ..^ 1]
      let eq = s.find('=')
      if eq > 0:
        let val = s[eq + 1 ..^ 1].strip(leading = true, trailing = true, chars = {'\0', ' ', '\t', '\r', '\n'})
        parts[s[0 ..< eq]] = val
  let ptype = parts.getOrDefault("proj", "stere")
  result.lat0 = parseFloat(parts.getOrDefault("lat_0", "90"))
  result.lon0 = parseFloat(parts.getOrDefault("lon_0", "0"))
  result.latTs = parseFloat(parts.getOrDefault("lat_ts", "0"))
  result.phi0Rad = degToRad(result.lat0)
  result.lam0Rad = degToRad(result.lon0)
  result.R = Wgs84A
  if ptype == "stere":
    result.kind = pkStere
    result.chi0Rad = conformalLat(result.phi0Rad)
  elif ptype == "gnom":
    result.kind = pkGnom
  else:
    raise newException(ValueError, "Unsupported projection: " & ptype)

proc dkCompositeProjection*(): Projection =
  result = Projection(
    kind: pkStere,
    lat0: 56.0, lon0: 10.5666, latTs: 56.0,
  )
  result.phi0Rad = degToRad(56.0)
  result.lam0Rad = degToRad(10.5666)
  result.R = Wgs84A
  result.chi0Rad = conformalLat(result.phi0Rad)

proc forward*(p: Projection, lat, lon: float64): tuple[x, y: float64] =
  let phi = degToRad(lat)
  let lam = degToRad(lon)
  let dlam = lam - p.lam0Rad
  case p.kind
  of pkStere:
    let chi = conformalLat(phi)
    let chi0 = p.chi0Rad
    let denom = 1.0 + sin(chi0) * sin(chi) + cos(chi0) * cos(chi) * cos(dlam)
    let k = 2.0 * p.R / denom
    result.x = k * cos(chi) * sin(dlam)
    result.y = k * (cos(chi0) * sin(chi) - sin(chi0) * cos(chi) * cos(dlam))
  of pkGnom:
    let phi0 = p.phi0Rad
    let cosC = sin(phi0) * sin(phi) + cos(phi0) * cos(phi) * cos(dlam)
    result.x = p.R * cos(phi) * sin(dlam) / cosC
    result.y = p.R * (cos(phi0) * sin(phi) - sin(phi0) * cos(phi) * cos(dlam)) / cosC

proc inverse*(p: Projection, x, y: float64): tuple[lat, lon: float64] =
  let rho = sqrt(x * x + y * y)
  case p.kind
  of pkStere:
    let chi0 = p.chi0Rad
    if rho < 1e-10:
      result.lat = p.lat0
      result.lon = p.lon0
      return
    let c = 2.0 * arctan(rho / (2.0 * p.R))
    let sinC = sin(c)
    let cosC = cos(c)
    let chi = arcsin(cosC * sin(chi0) + y * sinC * cos(chi0) / rho)
    let lam = p.lam0Rad + arctan2(x * sinC,
                                  rho * cosC * cos(chi0) - y * sinC * sin(chi0))
    result.lat = radToDeg(geodeticFromConformal(chi))
    result.lon = radToDeg(lam)
  of pkGnom:
    let phi0 = p.phi0Rad
    if rho < 1e-10:
      result.lat = p.lat0
      result.lon = p.lon0
      return
    let c = arctan(rho / p.R)
    let sinC = sin(c)
    let cosC = cos(c)
    let phi = arcsin(cosC * sin(phi0) + y * sinC * cos(phi0) / rho)
    let lam = p.lam0Rad + arctan2(x * sinC,
                                  rho * cosC * cos(phi0) - y * sinC * sin(phi0))
    result.lat = radToDeg(phi)
    result.lon = radToDeg(lam)

proc viewExtent*(p: Projection, zoom: float64): Extent =
  let (cx, cy) = p.forward(CenterLat, CenterLon)
  let w = BaseWidthM / zoom
  let h = w * 3.0 / 4.0
  result = (cx - w / 2.0, cx + w / 2.0, cy - h / 2.0, cy + h / 2.0)

# --- Vincenty geodesic ---

proc vincentyInverse*(lon1, lat1, lon2, lat2: float64): tuple[az, baz, dist: float64] =
  let
    a = Wgs84A
    f = Wgs84F
    b = Wgs84B
    phi1 = degToRad(lat1)
    phi2 = degToRad(lat2)
    l = degToRad(lon2 - lon1)
  let u1 = arctan((1.0 - f) * tan(phi1))
  let u2 = arctan((1.0 - f) * tan(phi2))
  let sinU1 = sin(u1); let cosU1 = cos(u1)
  let sinU2 = sin(u2); let cosU2 = cos(u2)
  var
    lambda = l
    lambdaP = 2.0 * PI
    sinSigma = 0.0
    cosSigma = 1.0
    sigma = 0.0
    cosSqAlpha = 1.0
    cos2SigmaM = 1.0
  for iter in 0 ..< 100:
    let sinLambda = sin(lambda)
    let cosLambda = cos(lambda)
    sinSigma = sqrt((cosU2 * sinLambda) * (cosU2 * sinLambda) +
                    (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda) *
                    (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda))
    if sinSigma == 0.0:
      return (0.0, 0.0, 0.0)  # coincident
    cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
    sigma = arctan2(sinSigma, cosSigma)
    let sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma
    cosSqAlpha = 1.0 - sinAlpha * sinAlpha
    if cosSqAlpha == 0.0:
      cos2SigmaM = 0.0
    else:
      cos2SigmaM = cosSigma - 2.0 * sinU1 * sinU2 / cosSqAlpha
    let c = f / 16.0 * cosSqAlpha * (4.0 + f * (4.0 - 3.0 * cosSqAlpha))
    lambdaP = lambda
    lambda = l + (1.0 - c) * f * sinAlpha *
             (sigma + c * sinSigma * (cos2SigmaM + c * cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM)))
    if abs(lambda - lambdaP) < 1e-12:
      break
  let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
  let bigA = 1.0 + uSq / 16384.0 * (4096.0 + uSq * (-768.0 + uSq * (320.0 - 175.0 * uSq)))
  let bigB = uSq / 1024.0 * (256.0 + uSq * (-128.0 + uSq * (74.0 - 47.0 * uSq)))
  let deltaSigma = bigB * sinSigma * (cos2SigmaM + bigB / 4.0 * (cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM) - bigB / 6.0 * cos2SigmaM * (-3.0 + 4.0 * sinSigma * sinSigma) * (-3.0 + 4.0 * cos2SigmaM * cos2SigmaM)))
  result.dist = b * bigA * (sigma - deltaSigma)
  let fwdAz = arctan2(cosU2 * sin(lambda),
                      cosU1 * sinU2 - sinU1 * cosU2 * cos(lambda))
  let fwdAzN = (radToDeg(fwdAz) + 360.0) mod 360.0
  let backAz = arctan2(-cosU1 * sin(lambda),
                       sinU1 * cosU2 - cosU1 * sinU2 * cos(lambda))
  let backAzN = (radToDeg(backAz) + 360.0) mod 360.0
  result.az = fwdAzN
  result.baz = backAzN

proc vincentyForward*(lon, lat, az, dist: float64): tuple[lon2, lat2: float64] =
  let
    a = Wgs84A
    f = Wgs84F
    b = Wgs84B
    phi1 = degToRad(lat)
  let alpha1 = degToRad(az)
  let sinAlpha1 = sin(alpha1)
  let cosAlpha1 = cos(alpha1)
  let tanU1 = (1.0 - f) * tan(phi1)
  let cosU1 = 1.0 / sqrt(1.0 + tanU1 * tanU1)
  let sinU1 = tanU1 * cosU1
  let sigma1 = arctan2(tanU1, cosAlpha1)
  let sinAlpha = cosU1 * sinAlpha1
  let cosSqAlpha = 1.0 - sinAlpha * sinAlpha
  let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
  let bigA = 1.0 + uSq / 16384.0 * (4096.0 + uSq * (-768.0 + uSq * (320.0 - 175.0 * uSq)))
  let bigB = uSq / 1024.0 * (256.0 + uSq * (-128.0 + uSq * (74.0 - 47.0 * uSq)))
  var
    sigma = dist / (b * bigA)
    sigmaP = 2.0 * PI
    cos2SigmaM = 0.0
    sinSigma = 0.0
    cosSigma = 1.0
  for iter in 0 ..< 100:
    cos2SigmaM = cos(2.0 * sigma1 + sigma)
    sinSigma = sin(sigma)
    cosSigma = cos(sigma)
    let deltaSigma = bigB * sinSigma * (cos2SigmaM + bigB / 4.0 * (cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM) - bigB / 6.0 * cos2SigmaM * (-3.0 + 4.0 * sinSigma * sinSigma) * (-3.0 + 4.0 * cos2SigmaM * cos2SigmaM)))
    sigmaP = sigma
    sigma = dist / (b * bigA) + deltaSigma
    if abs(sigma - sigmaP) < 1e-12:
      break
  let tmp = sinU1 * sinSigma - cosU1 * cosSigma * cosAlpha1
  let phi2 = arctan2(sinU1 * cosSigma + cosU1 * sinSigma * cosAlpha1,
                     (1.0 - f) * sqrt(sinAlpha * sinAlpha + tmp * tmp))
  let lam = arctan2(sinSigma * sinAlpha1, cosU1 * cosSigma - sinU1 * sinSigma * cosAlpha1)
  let c = f / 16.0 * cosSqAlpha * (4.0 + f * (4.0 - 3.0 * cosSqAlpha))
  let l = lam - (1.0 - c) * f * sinAlpha * (sigma + c * sinSigma * (cos2SigmaM + c * cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM)))
  result.lon2 = lon + radToDeg(l)
  result.lat2 = radToDeg(phi2)
