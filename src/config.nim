import std/[math, times, strutils]

const
  DmiRadarApi* = "https://opendataapi.dmi.dk/v1/radardata"
  DmiMetObsApi* = "https://opendataapi.dmi.dk/v2/metObs"
  DmiLightningApi* = "https://opendataapi.dmi.dk/v2/lightningdata"

  EumWmsUrl* = "https://view.eumetsat.int/geoserver/wms"
  EumFetchW* = 4096
  EumFetchH* = 3072

  # Safety limit for the WMS GetMap bbox. CRS:84 covers the whole globe,
  # but clamping the requested geographic extent guards against feeding the
  # provider an out-of-swath area if the view is ever widened. Denmark sits
  # well inside this, so it's currently a no-op for the normal framing.
  WmsExtentLimit* = 77.0

  GibsWmsUrl* = "https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi"
  GibsLayer* = "MODIS_Terra_CorrectedReflectance_TrueColor"

  # HTTP fetch timeouts (ms), passed to httputil's get calls.
  RadarFetchTimeoutMs* = 180000
  SatFetchTimeoutMs* = 180000
  GibsProbeTimeoutMs* = 30000

  DataDir* = "data"

  CenterLon* = 11.0 + 46.0 / 60.0
  CenterLat* = 55.0 + 58.0 / 60.0
  BaseWidthM* = 1_050_000.0

  # PseudoCappi composite output grid.
  CompositeGridNx* = 1200
  CompositeMargin* = 0.02

  WindBbox* = "3,52,21,60"
  # OGC API page-size cap for the wind query. The ±10 min window over the
  # Danish bbox yields only ~30 stations' observations, but we set this very
  # high (3+ orders of magnitude) so every feature arrives in one response
  # without any pagination handling.
  WindFetchLimit* = 300000

  MaxStationRadiusKm* = 75.0

  # --- Lightning ---
  # Wider than the wind bbox — catches strikes over the North Sea and
  # Norwegian coast so nearby storms aren't clipped at the Danish shoreline.
  LightningBbox* = "0,52,24,62"
  LightningCacheFile* = "lightning.json"
  # Rolling window kept in the cache and rendered. Pruning and the fetch
  # window are both anchored to the radar scan timestamp, so the rendered
  # ages match the radar frame the viewer is looking at.
  LightningWindowHours* = 3.0
  # Linear fade: opacity = 1 - ageHours / LightningWindowHours, clamped to [0, 1].
  # 100% at 0h → 0% at 3h, deleted after 3h.
  LightningFetchLimit* = 300000 # API max
  LightningMaxPages* = 10 # safety cap; ~3M strikes across Denmark
  LightningFetchOverlapMinutes* = 2 # dedup-by-id absorbs the overlap
  LightningDiamondR* = 5.0 # half-diagonal in canvas pixels
  LightningFillR* = 0.75.float32
  LightningFillG* = 0.0.float32
  LightningFillB* = 1.0.float32
  LightningOutlineR* = 0.0.float32
  LightningOutlineG* = 0.0.float32
  LightningOutlineB* = 0.0.float32
  LightningOutlineWidth* = 1.0

  ArrowColorR* = 0x2E.float32 / 255.0
  ArrowColorG* = 0x70.float32 / 255.0
  ArrowColorB* = 0xFF.float32 / 255.0
  ArrowColorA* = 0.55.float32
  ArrowLengthM* = 41000.0
  WindFontSize* = 22.0
  WindLabelStrokeWidth* = 3.0

  CoastColorHex* = "#63666A"

  CanvasW* = 1600
  CanvasH* = 1200

type
  WindSite* = tuple[lon, lat: float64]

  CollectionKind* = enum
    ckComposite, ckPseudoCappi

  SatSource* = enum
    ssGeocolour, ssEumetsatMtg, ssEumetsatMsg, ssGibsModis, ssNone

  EumLayer* = tuple[name: string, cadence: int]

proc eumLayer*(src: SatSource): EumLayer =
  case src
  of ssGeocolour: ("mtg_fd:rgb_geocolour", 10)
  of ssEumetsatMtg: ("mtg_fd:rgb_truecolour", 10)
  of ssEumetsatMsg: ("msg_fes:rgb_naturalenhncd", 15)
  else: ("mtg_fd:rgb_geocolour", 10)

const
  WindSites* = [
    (15.06, 55.24),                                     # Bornholm
    (12.33, 55.30),                                     # Stevns
    (11.19, 56.22),                                     # Kattegat
    (10.60, 55.17),                                     # Fyn
    (8.60, 55.31),                                      # Esbjerg
    (9.60, 57.15),                                      # Nordjylland
    (9.09, 56.29),                                      # Karup
    (4.85, 56.35),                                      # Nordsøen
  ]

  DbzBoundaries* = [5.float32, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 75]

  DbzColors* = [
    (0xB0.float32, 0xF0.float32, 0xFF.float32),         #  5-10  pale cyan
    (0x00.float32, 0xB0.float32, 0xFF.float32),         # 10-15  light blue
    (0x00.float32, 0xE0.float32, 0x00.float32),         # 15-20  green
    (0x00.float32, 0xA0.float32, 0x00.float32),         # 20-25  dark green
    (0xC8.float32, 0xE0.float32, 0x00.float32),         # 25-30  yellow-green
    (0xFF.float32, 0xFF.float32, 0x00.float32),         # 30-35  yellow
    (0xFF.float32, 0xA0.float32, 0x00.float32),         # 35-40  orange
    (0xFF.float32, 0x50.float32, 0x00.float32),         # 40-45  red-orange
    (0xFF.float32, 0x00.float32, 0x00.float32),         # 45-50  red
    (0xC0.float32, 0x00.float32, 0xC0.float32),         # 50-55  magenta
    (0xFF.float32, 0xFF.float32, 0xFF.float32),         # 55-75  white
  ]

proc dbzToRgba*(dbz: float32): tuple[r, g, b, a: float32] =
  if dbz.isNaN or dbz < DbzBoundaries[0]:
    return (0.float32, 0, 0, 0)
  for i in 0 .. DbzColors.high:
    if dbz < DbzBoundaries[i + 1]:
      let c = DbzColors[i]
      return (c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, 1.0)
  return (1.0, 1.0, 1.0, 1.0)

type
  AppConfig* = object
    outDir*: string
    collection*: CollectionKind
    satSource*: SatSource
    noSatellite*: bool
    noWind*: bool
    noLightning*: bool
    minDbz*: float32
    despeckle*: bool
    zoom*: float64
    fontPath*: string

proc defaultConfig*(): AppConfig =
  result.outDir = "."
  result.collection = ckPseudoCappi
  result.satSource = ssGeocolour
  result.noSatellite = false
  result.noWind = false
  result.noLightning = false
  result.minDbz = 10.0
  result.despeckle = false
  result.zoom = 1.0
  result.fontPath = ""

proc parseIsoUtc*(s: string): Time =
  ## Parse an ISO-8601 timestamp (with trailing 'Z' or a numeric offset)
  ## into a UTC `Time`. Handles the `...Z` form used by the DMI/EUMETSAT
  ## APIs by rewriting it to `+00:00` before `parse`. Also strips fractional
  ## seconds (the DMI lightning API returns e.g. `...19:36:21.735000Z`),
  ## which Nim's `yyyy-MM-dd'T'HH:mm:sszzz` format cannot parse.
  var t = s.replace("Z", "+00:00")
  let dot = t.find('.')
  if dot >= 0:
    # The offset may be negative (`...21.735000-05:00`): search for both
    # signs. Starting after the dot means the date's '-' is never seen.
    let tzStart = t.find({'+', '-'}, start = dot)
    if tzStart >= 0:
      t = t[0 ..< dot] & t[tzStart .. ^1]
  result = parse(t, "yyyy-MM-dd'T'HH:mm:sszzz", utc()).toTime()

proc formatIsoUtc*(t: Time): string =
  ## Format a `Time` as an ISO-8601 UTC string (`...Z`), the form expected
  ## by the DMI/EUMETSAT API query parameters. Pairs with `parseIsoUtc`.
  result = t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
