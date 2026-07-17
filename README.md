# met2img (Nim rewrite)

**Meteorological visualisation — radar + wind + lightning overlaid on satellite imagery for Denmark.**

This is a Nim rewrite of the Python project [`met2img`](../met2img.py). It is an experiment in porting a scientific Python pipeline — numpy, h5py, matplotlib, cartopy, pyproj, scipy — to pure Nim using Nim-native libraries. The core functionality is retained (fetch DMI radar + wind + lightning, overlay on satellite imagery, render a 1600×1200 PNG), but the implementation differs where Python libraries have no direct Nim equivalent.

## What it does

- **Radar data** — downloads the newest ODIM_H5 radar data from DMI's open data API. Supports the `composite` (single pre-gridded file) and `pseudoCappi` (multiple station files, reprojected and max-blended) collections.
- **Wind observations** — fetches wind direction and speed from DMI's meteorological observation API, rendered as semi-transparent arrows at 8 fixed anchor points across Denmark. Positions never move between runs; only direction and speed change.
- **Lightning observations** — fetches triangulated lightning strikes from DMI's lightning data API over a rolling 3-hour window (anchored to the radar scan time) and renders them as small bright-purple diamonds with a thin black outline. Markers fade linearly with age: 100% at 0h → 0% at 3h. A persistent rolling cache (`data/lightning.json`) accumulates strikes across runs with id-based dedup and an incremental fetch with a 2-minute overlap, so only the delta is requested each cron cycle.
- **Satellite background** — downloads a satellite image via WMS GetMap. Supports EUMETSAT MTG GeoColor (day/night blend, 10-minute cadence), MTG true-color, MSG natural color, and NASA GIBS MODIS Terra true-color (daily, razor-sharp). Falls back to GIBS MODIS if an EUMETSAT source fails.
- **Coastlines** — draws simplified Natural Earth 10m coastlines from a bundled GeoJSON file.
- **Output** — a 1600×1200 PNG with DMI-style stepped reflectivity colors, wind arrows with speed labels (m/s), lightning diamonds, and coastlines. Filename: `radar_YYYYMMDD-HHMM.png` (UTC, from the radar scan time).

## Scope differences from the Python version

This rewrite intentionally narrows some scope. See the [design notes](#what-was-replaced) below for the rationale.

| Feature | Python | Nim |
|---------|--------|-----|
| Radar collections | `composite`, `pseudoCappi`, `volume` | `composite`, `pseudoCappi` |
| Satellite sources | geocolour, eumetsat-mtg, eumetsat-msg, gibs-modis, none | geocolour, eumetsat-mtg, eumetsat-msg, gibs-modis, none |
| GIBS delivery | WMTS (tile stitching via cartopy) | WMS (single GetMap image) |
| EUMETSAT fallback | falls back to GIBS on failure | falls back to GIBS on failure |
| Coastlines | cartopy Natural Earth (rendered by matplotlib) | bundled GeoJSON (rendered by pixie) |
| Projections | pyproj / cartopy CRS | pure-Nim implementation |
| Interpolation | scipy.griddata, scipy.RegularGridInterpolator | pure-Nim bilinear |
| Rendering | matplotlib + cartopy | pixie (2D graphics) |
| Tensor math | numpy | Arraymancer |

## Installation

### Prerequisites

- **Nim** 2.0+ (tested with 2.2.4)
- **HDF5 development libraries** (provides `libhdf5.so` and headers)

```bash
# Fedora
sudo dnf install -y hdf5-devel

# Debian/Ubuntu
sudo apt install -y libhdf5-dev
```

### Nim dependencies

All Nim libraries are installed automatically via nimble when you first build:

```bash
nimble install nimhdf5 arraymancer pixie
```

Or simply build the project — nimble resolves dependencies from `met2img.nimble`:

```bash
bash build.sh
```

## Usage

```bash
./met2img
```

The binary is self-contained — coastline data is embedded at compile time, so it can be run from any directory without external data files. The only runtime requirement is a `data/` folder for the radar/wind cache (created automatically).

Output: `radar_YYYYMMDD-HHMM.png` (UTC timestamp from radar scan time)

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--outdir DIR` | `.` | Output directory |
| `--collection` | `pseudoCappi` | Radar collection: `composite`, `pseudoCappi` |
| `--sat-source` | `geocolour` | Satellite source: `geocolour`, `eumetsat-mtg`, `eumetsat-msg`, `gibs-modis`, `none` |
| `--zoom N` | `1.0` | Zoom factor (1 = full composite, 2 = Denmark+, 3 = tight, 4 = core) |
| `--no-satellite` | — | Skip satellite background (shortcut for `--sat-source none`) |
| `--no-wind` | — | Skip wind arrows |
| `--no-lightning` | — | Skip lightning diamonds |
| `--min-dbz N` | `10.0` | Mask radar echoes below this dBZ threshold |
| `--despeckle` | — | Remove isolated single-pixel echoes (3×3 median filter) |
| `--font PATH` | embedded | Use a specific `.ttf`/`.otf` font for wind labels (default: bundled DejaVuSans-Bold) |

Both `--flag value` and `--flag=value` forms are accepted. Value-taking flags error out if no value is supplied. `--zoom` must be positive and `--min-dbz` must be a finite number; `--outdir` is created recursively (parent directories included).

### Satellite sources

- **geocolour** (default) — MTG GeoColor, geostationary, 10 min cadence. Blends true-color by day with infrared at night. Best all-around choice; works around the clock.
- **eumetsat-mtg** — MTG true-color, geostationary, 10 min cadence. Sharper but visible-light only — the eastern side goes dark/transparent after sunset, which triggers an automatic fallback to GIBS MODIS.
- **eumetsat-msg** — MSG natural color, geostationary, 15 min cadence.
- **gibs-modis** — MODIS Terra true-color, ~250 m resolution, daily morning overpass (~09 UTC). Razor-sharp but clouds may not match the radar scan time. GIBS has a ~24h processing lag; the tool probes the date and steps back up to 3 days to find the most recent day with real (non-black) tiles.
- **none** — No satellite background (black canvas with radar + coastlines + wind).

When an EUMETSAT source fails or returns a fully transparent image (e.g. true-color at night), the tool detects this explicitly and falls back to GIBS daily MODIS.

### Build flags

The build script (`build.sh`) compiles with:

```bash
nim c -d:release -d:H5_FUTURE -d:ssl -o:met2img src/met2img.nim
```

| Flag | Why |
|------|-----|
| `-d:release` | Optimized build |
| `-d:H5_FUTURE` | Required for HDF5 1.14+ (uses versioned `H5Oget_info2` symbols; without it, the binary compiles but crashes at runtime) |
| `-d:ssl` | Enables HTTPS support in stdlib's HTTP client (DMI and EUMETSAT APIs require TLS) |

## Data sources

- **Radar & wind**: [DMI Open Data API](https://opendataapi.dmi.dk)
- **Lightning**: [DMI Lightning Data API](https://www.dmi.dk/friedata/dokumentation/lightning-data-api) (part of the Open Data API)
- **Satellite**: [EUMETSAT WMS](https://view.eumetsat.int/geoserver/wms) (MTG GeoColor, MTG true-color, MSG natural color) / [NASA GIBS WMS](https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi) (MODIS Terra true-color)
- **Coastlines**: [Natural Earth](https://www.naturalearthdata.com/) 10m coastline, clipped to Europe and simplified (embedded in the binary at compile time via `staticRead`; ~300 KB)

## Caching

Downloaded DMI data is stored in a `data/` folder and reused on subsequent runs:

- **Radar** — `.h5` files are kept in `data/`. DMI filenames encode the scan timestamp, so an identical filename means identical data. If the cached file matches the newest available from the API, the download is skipped. Leftover `.h5.tmp` files from interrupted downloads are cleaned up on each run.
- **Wind** — `wind_<scanstamp>.json` is saved alongside the radar file, keyed to the same scan timestamp. An empty result (no observations found) is not cached, so a transient API failure won't poison future runs for the same scan time.
- **Lightning** — `lightning.json` is a **persistent rolling cache** (unlike radar/wind, which are replaced each run). It stores every strike observed within the 3-hour window ending at the most recent radar scan time, plus that scan time as `lastFetch`. Each run:
  1. If the cache is empty/missing → full fetch `scanTime−3h .. scanTime`, reset the cache.
  2. If `scanTime` is newer than `lastFetch` → incremental fetch `lastFetch−2min .. scanTime` (the overlap guards late-arriving records; dedup is by the DMI feature `id`, which is stable across responses, so re-fetching the overlap is harmless).
  3. If `scanTime` is not newer than `lastFetch` (manual rerun against an older cached radar, or a radar feed regression) → skip the fetch entirely and just re-prune against the new `scanTime` so opacity/ageing stays correct.
  4. Prune strikes with `observed < scanTime−3h`, then save.
  
  A fetch failure is non-fatal: the existing cache is preserved (possibly empty) and the run continues with whatever strikes are on hand. Pagination is handled via the response's `rel="next"` links with a 10-page safety cap (~3M strikes across Denmark — well beyond any realistic storm), and a fallback heuristic flags a full page without a next link.
- **Cleanup** — old `.h5` and `wind_*.json` files are deleted only after the new radar file has been written successfully, so a failed download never leaves `data/` empty. The lightning cache is untouched by these cleanup loops (they only match `*.h5` and `wind_*.json`); it is pruned in place on every run as described above.

## Deployment

The binary is self-contained (~2.4 MB) — coastline data is embedded, and the only runtime dependency is the HDF5 shared library (`libhdf5.so`). To deploy to another machine (e.g. a Raspberry Pi driving an e-ink display):

1. Install the HDF5 runtime library on the target:
   ```bash
   # Fedora
   sudo dnf install -y hdf5
   # Debian/Ubuntu
   sudo apt install -y libhdf5-103
   ```

2. Copy the binary:
   ```bash
   scp met2img user@target:/usr/local/bin/
   ```

3. Run from anywhere:
   ```bash
   met2img --outdir /var/lib/met2img
   ```

The `data/` cache directory is created relative to the current working directory. For a deployment, run from a fixed directory (e.g. `/var/lib/met2img`) or wrap with `cd` in the cron entry.

### Cross-compiling for 32-bit (i386)

To deploy on a 32-bit machine (e.g. an anemic ARM box or legacy i386 system), cross-compile from your 64-bit host:

```bash
bash build.sh 32
```

This produces `met2img_i386` — a 32-bit ELF binary. The build requires 32-bit C libraries on the compile host:

```bash
# Fedora — install 32-bit development libraries
sudo dnf install -y glibc-devel.i686 hdf5.i686 openblas.i686 openblas-devel.i686 libatomic.i686

# The hdf5-devel.i686 package conflicts with the 64-bit headers, so manually
# create the .so symlink that nimhdf5's runtime dlopen expects:
sudo ln -s libhdf5.so.310 /usr/lib/libhdf5.so
```

| Library | Required by | Why |
|---------|------------|-----|
| `glibc-devel.i686` | Nim stdlib | Provides `gnu/stubs-32.h` and 32-bit crt objects |
| `hdf5.i686` | nimhdf5 | 32-bit `libhdf5.so` (loaded at runtime via `dynlib`) |
| `openblas.i686` | arraymancer (BLAS/LAPACK) | 32-bit `libopenblas.so` (loaded at runtime via `dynlib`) |
| `openblas-devel.i686` | arraymancer | Provides the `.so` symlink for linking |
| `libatomic.i686` | gcc | 32-bit atomic operations library |

The 32-bit binary requires the corresponding 32-bit runtime libraries on the target machine (`libhdf5.so`, `libopenblas.so`, `libatomic.so`, `libssl.so`, and 32-bit glibc).

**Why the extra flags?** Nim's `nim.cfg` has cross-compiler entries for ARM and RISC-V but not for i386-on-amd64. The build script passes `--cpu:i386` (Nim generates 32-bit code), `--passC:"-m32"` (gcc produces 32-bit objects), and `--passL:"-m32"` (linker produces a 32-bit binary). Each target also gets its own `--nimcache` directory to avoid mixing 32/64-bit object files between builds. On a native 32-bit system, these flags are unnecessary — a plain `nim c` produces 32-bit code by default.

## Project organization

The codebase is split into 12 small modules (~1,900 lines total), each with a single responsibility. The split follows the Python version's logical boundaries but adapts to Nim's module system and the available libraries.

```
met2nim/
├── src/
│   ├── met2img.nim     # Entry point: CLI parsing, orchestration
│   ├── config.nim      # Constants, colormap, wind sites, CLI config type
│   ├── geo.nim         # Pure-Nim map projections + geodesics
│   ├── h5read.nim      # ODIM_H5 reader (nimhdf5 → Arraymancer tensors)
│   ├── interp.nim      # Bilinear resampling + max-blend (pseudoCappi)
│   ├── radar.nim       # DMI API fetch, download/cache, parse dispatch
│   ├── wind.nim        # DMI metObs fetch, site assignment, arrow geometry
│   ├── lightning.nim   # DMI lightning fetch, rolling 3h cache, opacity aging
│   ├── sat.nim         # EUMETSAT WMS GetMap → pixie Image
│   ├── coast.nim       # GeoJSON coastline loader + renderer
│   ├── render.nim      # Compositing pipeline (pixie canvas)
│   └── httputil.nim    # Shared HTTP helpers (GET json/bytes)
├── met2img.nimble      # Nimble package file (deps, bin target, test task, srcDir = "src")
├── build.sh            # Build script
├── fonts/              # Bundled DejaVuSans-Bold.ttf (build-time only, embedded via staticRead)
├── coast.geojson       # Coastline data (build-time only, embedded via staticRead)
├── data/               # Radar/wind/lightning cache
└── autotest/           # Cron output + log
```

### Module responsibilities

| Module | Responsibility | Replaces (Python) | Nim library |
|--------|---------------|-------------------|-------------|
| `config` | All constants — API URLs, map center, zoom, colormap, wind sites, arrow style. Pure data, no logic. | module-level constants | std/math |
| `geo` | Stereographic + gnomonic forward/inverse projections, Vincenty geodesic inverse/forward, view extent calculation. | cartopy CRS + pyproj Geod | std/math (pure Nim) |
| `h5read` | Reads ODIM_H5 datasets and group attributes via nimhdf5, applies gain/offset scaling, returns Arraymancer `Tensor[float32]`. Handles both composite (single file) and pseudoCappi (per-station) reads. | h5py + numpy | nimhdf5, arraymancer |
| `interp` | Bilinear resampling of station-local grids onto a common output grid, then max-blends (strongest echo wins). | scipy.interpolate.griddata / RegularGridInterpolator | arraymancer |
| `radar` | Fetches radar file metadata from DMI API (JSON), manages download + cache + cleanup, dispatches parsing to h5read/interp based on collection kind. | met2img.py fetch + cache functions | std/httpclient (via httputil) |
| `wind` | Fetches wind_dir + wind_speed from DMI metObs API, assigns stations to fixed anchor sites (Voronoi-style nearest with radius cutoff via Vincenty geodesic), computes arrow polygon geometry, manages JSON cache. | met2img.py wind functions + pyproj Geod | std/httpclient, geo |
| `lightning` | Fetches triangulated lightning strikes from the DMI lightning API, maintains a persistent rolling 3h cache (`lightning.json`) with incremental fetch + id-based dedup + age-based prune, computes opacity aging. | (new — no Python equivalent) | std/httpclient, geo (via render), std/json, std/times |
| `sat` | Downloads EUMETSAT GeoColor WMS GetMap image, decodes PNG to pixie Image, computes the geographic bounding box of the current view. | met2img.py satellite functions | pixie |
| `coast` | Parses the embedded GeoJSON (loaded from a string, not a file), projects lat/lon coordinates through the map projection to canvas pixels, strokes coastline polylines. | cartopy cfeature.COASTLINE | pixie, std/json |
| `render` | The compositing pipeline: black canvas → satellite background (per-pixel reprojection) → radar overlay (per-pixel colormap + alpha blend) → coastlines → wind arrow polygons + speed labels with outlined text → lightning diamonds (purple fill + black outline, aged alpha) → save PNG. Also contains the 3×3 median despeckle filter. | matplotlib + cartopy rendering | pixie, arraymancer |
| `httputil` | Two shared procs (`httpGetJson`, `httpGetBytes`) used by radar, wind, and sat modules. | urllib.request | std/httpclient |

### Why not one file?

The Python version is a single 1,316-line `met2img.py`. The Nim version splits into 12 modules under `src/` because:

1. **Nim's import system** makes cross-module calls explicit — you can't accidentally reach into another module's private state. This encourages clean boundaries.
2. **Compile times** — smaller modules let Nim's incremental compilation cache individual `.nim` files. Changing `render.nim` doesn't recompile `geo.nim`.
3. **Separation of concerns** — the projection math, HDF5 reading, API fetching, and rendering are fundamentally different domains. Separating them makes each piece testable and swappable.

Source files live in `src/` (declared via `srcDir = "src"` in the nimble file), while non-source files — the build script, bundled GeoJSON data, cache, and output — stay at the project root. This keeps `ls` on the root meaningful and separates code from data.

## Performance

Both versions were timed with cached radar/wind data (no network downloads) to isolate processing performance. All runs use the `pseudoCappi` collection, default settings unless noted, and output to a 1600×1200 PNG.

| Scenario | Python | Nim | Speedup |
|----------|--------|-----|---------|
| Radar only (no sat, no wind) | 5.86s | 2.08s | 2.8× |
| Radar + wind (no sat) | 6.24s | 2.04s | 3.1× |
| Full pipeline (radar + wind + sat) | 30.56s | 6.64s | **4.6×** |
| Zoom 2 (radar + wind, no sat) | 7.46s | 3.49s | 2.1× |
| Despeckle (radar + wind, no sat) | 5.85s | 2.06s | 2.8× |

The Nim version is consistently 2–4.6× faster across all scenarios. The biggest win is the full pipeline (4.6×) where satellite reprojection — done per-pixel in native Nim vs cartopy's Python-wrapped C — benefits most from eliminating interpreter overhead.

### Caveats on the comparison

This is not a like-for-like benchmark. The Nim version takes some shortcuts the Python version does not:

- **Conformal-sphere projection** instead of full ellipsoidal PROJ (sub-pixel error, but less computation).
- **Nearest-neighbor radar sampling** instead of matplotlib's anti-aliased `imshow`.
- **Bilinear interpolation** instead of scipy's Delaunay-based `griddata` (the `volume` collection that uses it was dropped from scope).
- **pixie's rasterizer** instead of matplotlib's vector graphics pipeline (Agg backend).

That said, the performance difference is real and significant. The Python version's bottleneck is not the C libraries themselves (numpy, scipy, PROJ, HDF5 are all fast) but the Python glue between them — per-call marshalling, reference counting, and interpreter dispatch. cartopy's satellite reprojection calls back into Python for each CRS transform; matplotlib's figure assembly walks Python objects. The Nim version does the same work in straight native code with no interpreter overhead.

## What was replaced

The Python version depends on six major scientific Python libraries that have no direct Nim equivalent. Each was replaced with an alternative strategy:

### cartopy → pure-Nim projections + bundled GeoJSON

cartopy provides CRS objects, Natural Earth feature rendering, and satellite image reprojection. None of this exists in Nim. The replacement:

- **Projections** (`geo.nim`): Implemented stereographic and gnomonic forward/inverse projections from scratch using the conformal-sphere approach. Geodetic latitude is converted to conformal latitude (via the Gudermannian-like series expansion for WGS84), then spherical stereographic formulas are applied with R = WGS84 semi-major axis. The inverse uses a series expansion to convert conformal latitude back to geodetic. Accuracy is sub-pixel (~0.3% at view edges) — well within tolerance for a 1600×1200 image.

- **Coastlines** (`coast.nim` + `coast.geojson`): Natural Earth 10m coastline shapefile is clipped to a Europe bounding box (0°–25°E, 49°–62°N), simplified to ~500m tolerance, and bundled as a GeoJSON file. At runtime, each LineString is projected through the map projection and stroked on the pixie canvas. The clipping step is critical: the original shapefile has 14,000-point LineStrings spanning entire continents. Simplifying without clipping first drops the points within our view because Douglas-Peucker prioritizes the large-scale geometry.

- **Satellite reprojection** (`render.nim`): Instead of cartopy's `imshow` with CRS transform, the satellite image is reprojected per-pixel: each canvas pixel is mapped from projection coordinates → lat/lon (inverse projection) → satellite image pixel (nearest-neighbor). This is slower than cartopy's optimized reprojection but produces equivalent results at this resolution.

### pyproj → pure-Nim Vincenty geodesic

pyproj's `Geod.inv()` and `Geod.fwd()` have no Nim equivalent. I implemented Vincenty's inverse and forward formulas directly in `geo.nim` using WGS84 ellipsoid parameters (a = 6378137m, f = 1/298.257223563). The iterative solver converges in ~10–20 iterations. This is used for:

- Computing distances from wind stations to anchor sites (with a 75 km radius cutoff)
- Computing arrow endpoint coordinates (forward geodesic from the site, 1 km in the "to" azimuth, then projected to map coordinates)

### scipy.interpolate → pure-Nim bilinear interpolation

The pseudoCappi collection has 4 station files, each in a station-local gnomonic projection. They need to be reprojected onto a common stereographic output grid and max-blended. The replacement (`interp.nim`):

- For each output grid point: inverse-project to lat/lon, forward-project into the station's gnomonic projection, bilinearly sample the station's grid (with NaN propagation — if any neighbor is NaN, the result is NaN, meaning "no echo at this point").
- Max-blend across stations: the strongest echo wins (same as DMI's composite).
- Linear scan for grid cell lookup (no k-d tree needed because the grids are regular and small — 960×960 per station, 1200×1130 output).

The `volume` collection (raw polar scans needing scattered-point Delaunay triangulation + barycentric interpolation) was dropped from the rewrite scope because pure-Nim Delaunay is significant extra work. The `composite` and `pseudoCappi` paths cover the common use cases.

### numpy → Arraymancer

Arraymancer provides `Tensor[T]` — a numpy-like n-dimensional array with indexing, reshaping, and element-wise map operations. It's used for the 2D reflectivity fields. Key differences from numpy:

- `tensor.shape` returns a `DynamicStackArray[int]`, not a seq. Indexing with `shape[0]` is ambiguous; you must use `shape.data[0]`.
- No `flipud` — the pseudoCappi row flip (row 0 = north → row 0 = south) is done with a manual loop.
- `newTensorWith(shape, value)` creates and fills in one call, replacing `np.full(shape, value)`.
- Element-wise iteration uses `for v in tensor` (Arraymancer provides an `items` iterator).
- The `map` proc takes a closure: `tensor.map(proc(x: float32): float32 = ...)`.

### matplotlib + cartopy → pixie

matplotlib renders the figure (radar imshow, coastlines, wind polygons, text) and saves the PNG. cartopy provides the map projection and CRS-aware rendering. The replacement uses pixie — a full-featured 2D graphics library by treeform:

- **Canvas**: `newImage(1600, 1200)` creates an RGBA bitmap. `fill(rgba(0,0,0,255))` clears it to black.
- **Radar overlay**: Per-pixel — for each canvas pixel, map to radar grid (nearest-neighbor), look up the dBZ colormap, alpha-blend over the existing pixel. This replaces matplotlib's `imshow` with a `BoundaryNorm` + `ListedColormap`.
- **Coastlines**: `ctx.beginPath()` + `moveTo`/`lineTo` + `ctx.stroke()` for each LineString. `lineWidth = 1.5` for visibility.
- **Wind arrows**: `ctx.fill()` for the 7-vertex arrow polygons. `ctx.fillText` + `ctx.strokeText` for the speed labels with white outline.
- **PNG output**: `image.writeFile(path)` (pixie handles PNG encoding internally).

### EUMETSAT + GIBS satellite sources

The Python version uses cartopy's `add_wmts` for GIBS (tile stitching via owslib WMTS) and `imshow` with CRS transform for EUMETSAT. The Nim replacement uses WMS GetMap for both providers — a single HTTP request returns the full image, no tile stitching needed:

- **EUMETSAT** (`sat.nim`): WMS GetMap with `layers=` parameter selecting the layer (geocolour, true-colour, natural-color) and `time=` snapped to the nearest cadence slot (10 or 15 minutes). Returns a PNG with transparency.
- **GIBS** (`sat.nim`): WMS GetMap with `layers=MODIS_Terra_CorrectedReflectance_TrueColor` and `time=YYYY-MM-DD` (date only, daily). Returns a JPEG. A probe step downloads a small 100×100 image over central Europe and checks if it's entirely black (indicating tiles are still processing — GIBS has a ~24h lag). Steps back up to 3 days to find the most recent date with real tiles.
- **Fallback**: If an EUMETSAT source fails (e.g. true-color at night returns an empty/transparent image), the dispatcher automatically falls back to GIBS MODIS. This matches the Python version's behavior.

### h5py → nimhdf5

nimhdf5 is a Nim wrapper around the C HDF5 library. It provides:

- `H5open(path, "r")` — open file read-only (lazy: does not traverse the file tree).
- `h5f["dataset1/data1/data".dset_str]` — get a dataset by path (the `dset_str` distinct type disambiguates from group access).
- `dset.read(uint8)` — read dataset into a flat `seq[uint8]` (multi-dimensional datasets are flattened to 1D in row-major order; use `dset.shape` to recover dimensions).
- `h5f["what".grp_str].attrs["gain", float64]` — read group attribute by name (lazy: opens, reads, closes in one call).
- Attributes must be read with the correct type (`float64` for ODIM_H5 gain/offset/nodata/corner coords, `string` for projdef). A `readAttrF64` helper in `h5read.nim` handles cross-type coercion.

## Nim-specific notes

Several Nim language and ecosystem characteristics shaped the implementation:

### `distinct string` types in nimhdf5

nimhdf5 uses `dset_str` and `grp_str` (both `distinct string`) to disambiguate `h5f["path"]` overloads — one returns an `H5DataSet`, the other an `H5Group`. You must tag strings: `h5f["what".grp_str]` vs `h5f["dataset1/data1/data".dset_str]`. The two-arg `h5f[name, uint8]` form takes a plain string.

### `-d:H5_FUTURE` is mandatory on HDF5 1.14+

HDF5 1.14 deprecated the unversioned `H5Oget_info` C macro in favor of versioned symbols (`H5Oget_info2`). nimhdf5's default branch imports the unversioned symbol; the `-d:H5_FUTURE` branch uses the versioned one. Without this flag, the binary compiles but crashes at runtime with "could not import: H5Oget_info".

### `-d:ssl` required for HTTPS

Nim's stdlib HTTP client doesn't include SSL by default. Both DMI and EUMETSAT APIs use HTTPS, so `-d:ssl` must be passed at compile time (links against OpenSSL).

### `isNaN` ambiguity (math vs vmath)

Both `std/math` and `vmath` (transitively imported via pixie) export `isNaN`. In modules that import both (currently only `render.nim`), calling `.isNaN` is ambiguous and Nim can't resolve it. The workaround in those modules: `x != x` (NaN is the only value not equal to itself). In modules that don't import pixie (`config.nim`, `interp.nim`), `.isNaN` is used directly — there's no ambiguity there since only `std/math`'s overload is visible.

### Arraymancer's `DynamicStackArray` shape

`tensor.shape` returns a `Metadata = DynamicStackArray[int]` — a fixed-capacity stack array (max 6 dimensions), not a heap-allocated seq. The `[]` operator works but is typed as `Index = SomeSignedInt or BackwardsIndex`, which can cause type mismatch errors. Direct access via `shape.data[0]` is unambiguous.

### No `flipAxis` in Arraymancer

Unlike numpy's `flipud`/`fliplr`, Arraymancer has no array flip primitive. The pseudoCappi row flip (ODIM_H5 stores rows origin='upper', but bilinear interpolation needs ascending y) is done with a manual loop copying rows in reverse order.

### Pixie `Context` name collision

pixie's `Context` (the 2D canvas context) and arraymancer's `autograd.Context` (computational graph context) collide when both libraries are imported in the same module. Must qualify: `contexts.Context` in function signatures.

### Pixie `strokeText` and `fillText` alignment

Unlike `fillText` (which respects `ctx.textBaseline` — `MiddleBaseline`, `AlphabeticBaseline`, etc.), pixie's `strokeText` always uses `AlphabeticBaseline` regardless of the setting. The wind labels avoid this pitfall by calling the `Image`-level `fillText`/`strokeText` overloads that take a `Font` directly: both share one typeset arrangement, so the white outline and black fill are inherently aligned, and `MiddleAlign` centers the label on the arrow without any manual y-offset. The font itself is the bundled DejaVuSans-Bold loaded in-memory via `parseTtf` (see the `staticRead` note above).

### Pixie `beginPath()` between shapes

Without `ctx.beginPath()`, subpaths accumulate in the context's internal path. Each `fill()` or `stroke()` redraws ALL accumulated subpaths, causing:

- **Opacity stacking**: if you fill 8 arrow polygons without `beginPath()` between them, the first arrow is drawn 8 times (fully opaque), the second 7 times, etc. — only the last one has the correct opacity.
- **Performance**: each call redraws all previous shapes.

Always call `ctx.beginPath()` before starting a new shape.

### pixie's `Color` vs `ColorRGBA`

pixie (via chroma) has two color types: `Color` (float32, 0–1 range) and `ColorRGBA` (uint8, 0–255 range). Both are accepted by `ctx.fillStyle` via the `SomePaint` converter. Use `color(r, g, b, a)` for float32 0–1 values, `rgba(r, g, b, a)` for uint8 0–255 values. Be consistent with the range.

### Manual CLI parsing

Nim's `parseopt` module handles `--flag=value` but not `--flag value` (space-separated) cleanly — the value ends up in the next iteration as a positional argument. The rewrite uses a manual parser in `met2img.nim` that checks whether a flag needs a value and consumes the next argument if so. This handles both `--outdir /tmp` and `--outdir=/tmp` forms.

### `staticRead` for embedding data in the binary

Nim's `staticRead` reads a file at compile time and embeds its contents as a string constant in the binary. The coastline GeoJSON (~300 KB, 149 LineStrings) is embedded this way:

```nim
const coastData = staticRead("../coast.geojson")
```

The path is relative to the source file (hence `../` from `src/`). At runtime, the data is parsed from the string — no file I/O needed. The `coast.geojson` file at the project root is a build-time dependency only; it's not needed at runtime. This makes the binary self-contained and deployable as a single file.

The same mechanism embeds the wind-label font: `fonts/DejaVuSans-Bold.ttf` (~709 KB) is read at compile time and parsed in-memory with pixie's `parseTtf` (no system font path is required at runtime, so the binary still runs unchanged on the Raspberry Pi). A `--font PATH` flag overrides the bundled font when needed (e.g. for other glyph coverage); a bad path falls back to the embedded font with a warning.

### Vincenty geodesic in pure Nim

pyproj's `Geod.inv()` and `Geod.fwd()` have no Nim equivalent. Vincenty's formulas (inverse: compute distance + azimuth from two lat/lon points; forward: compute destination from start + azimuth + distance) are implemented iteratively in `geo.nim` using WGS84 ellipsoid parameters. The solver converges in ~10–20 iterations with a 1e-12 convergence threshold.

### Conformal-sphere stereographic projection

cartopy uses PROJ internally for the stereographic projection. The pure-Nim implementation uses the conformal-sphere approach:

1. Convert geodetic latitude (φ) to conformal latitude (χ) using the isometric latitude formula with WGS84 eccentricity.
2. Apply spherical stereographic formulas using χ and R = WGS84 semi-major axis (a = 6,378,137 m).
3. For the inverse, convert χ back to φ using a series expansion (A₁ sin 2χ + A₂ sin 4χ + ...).

This avoids implementing the full ellipsoidal stereographic (which would require iterative solving) at the cost of ~0.3% positional error at the view edges — less than one pixel at the 1600×1200 resolution.

The gnomonic projection (used by DMI's pseudoCappi station files) uses geodetic latitude directly with R = a. The error is ~124m at the station range limits, well within the 500m radar grid spacing.
