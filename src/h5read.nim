import nimhdf5
import arraymancer
import geo

const RadarDatasetPath = "dataset1/data1/data"

type
  RadarField* = object
    dbz*: Tensor[float32]
    extent*: Extent # [xmin, xmax, ymin, ymax] in projection metres
    proj*: Projection

proc failH5(path, msg: string) =
  raise newException(ValueError, "Radar file '" & path & "': " & msg)

proc readAttrF64(grp: H5Group, name: string, path: string): float64 =
  let kind = grp.attrs[name]
  case kind
  of dkFloat64: result = grp.attrs[name, float64]
  of dkFloat32: result = float64(grp.attrs[name, float32])
  of dkFloat: result = float64(grp.attrs[name, float])
  of dkInt, dkInt32: result = float64(grp.attrs[name, int32])
  of dkInt64: result = float64(grp.attrs[name, int64])
  of dkInt16: result = float64(grp.attrs[name, int16])
  of dkUInt8: result = float64(grp.attrs[name, uint8])
  of dkUInt16: result = float64(grp.attrs[name, uint16])
  of dkUInt32: result = float64(grp.attrs[name, uint32])
  else: failH5(path, "attr '" & name & "' has unexpected dtype: " & $kind)

proc readAttrStr(grp: H5Group, name: string, path: string): string =
  result = grp.attrs[name, string]

# --- Shared helpers ---

proc projectionExtent(whereGrp: H5Group, proj: Projection,
    path: string): Extent =
  # Project the four LL/LR/UL/UR corner attributes and return the
  # enclosing bbox in projection metres: (xmin, xmax, ymin, ymax).
  const cornerKeys = [("LL_lon", "LL_lat"), ("LR_lon", "LR_lat"),
                      ("UL_lon", "UL_lat"), ("UR_lon", "UR_lat")]
  result = (Inf, -Inf, Inf, -Inf)
  for (klon, klat) in cornerKeys:
    let lon = readAttrF64(whereGrp, klon, path)
    let lat = readAttrF64(whereGrp, klat, path)
    let (x, y) = proj.forward(lat, lon)
    result[0] = min(result[0], x)
    result[1] = max(result[1], x)
    result[2] = min(result[2], y)
    result[3] = max(result[3], y)

proc fillScaled[T](dest: var Tensor[float32], dset: H5DataSet,
                    gain, offset, nodata: float64) =
  let shape = dset.shape
  let rows = shape[0]
  let cols = shape[1]
  let raw = dset.read(T)
  for i in 0 ..< rows:
    for j in 0 ..< cols:
      let v = raw[i * cols + j]
      if float64(v) == nodata:
        dest[i, j] = NaN.float32
      else:
        dest[i, j] = float32(gain * float64(v) + offset)

proc readScaledDbz(dset: H5DataSet, gain, offset, nodata: float64,
                    path: string): Tensor[float32] =
  # Read the raw dataset and convert to float32 reflectivity via
  # dbz = gain * raw + offset, mapping `nodata` to NaN.
  let shape = dset.shape
  let rows = shape[0]
  let cols = shape[1]
  result = newTensor[float32]([rows, cols])
  case dset.dtypeAnyKind
  of dkUInt8: fillScaled[uint8](result, dset, gain, offset, nodata)
  of dkUInt16: fillScaled[uint16](result, dset, gain, offset, nodata)
  of dkUInt32: fillScaled[uint32](result, dset, gain, offset, nodata)
  of dkInt16: fillScaled[int16](result, dset, gain, offset, nodata)
  of dkInt8: fillScaled[int8](result, dset, gain, offset, nodata)
  else: failH5(path, "unexpected dataset dtype: " & $dset.dtypeAnyKind)

proc readWhatScaling(h5f: H5File, path: string): tuple[gain, offset,
    nodata: float64] =
  let whatGrp = h5f["what".grp_str]
  result.gain = readAttrF64(whatGrp, "gain", path)
  result.offset = readAttrF64(whatGrp, "offset", path)
  result.nodata = readAttrF64(whatGrp, "nodata", path)

proc readProjection(h5f: H5File, path: string): Projection =
  let whereGrp = h5f["where".grp_str]
  result = parseProjdef(readAttrStr(whereGrp, "projdef", path))

# --- Public readers ---

proc parseRadarH5*(path: string): RadarField =
  let h5f = H5open(path, "r")
  defer: discard h5f.close()

  let (gain, offset, nodata) = readWhatScaling(h5f, path)
  let proj = readProjection(h5f, path)
  let whereGrp = h5f["where".grp_str]
  let extent = projectionExtent(whereGrp, proj, path)

  let dset = h5f[RadarDatasetPath.dset_str]
  let dbz = readScaledDbz(dset, gain, offset, nodata, path)

  result = RadarField(dbz: dbz, extent: extent, proj: proj)

type
  PseudoCappiStation* = object
    dbz*: Tensor[float32] # rows 0 = south (flipped from file)
    xIn*: seq[float64]    # ascending x grid coords (station projection)
    yIn*: seq[float64]    # ascending y grid coords (station projection)
    stationProj*: Projection

proc readPseudoCappiStation*(path: string): PseudoCappiStation =
  let h5f = H5open(path, "r")
  defer: discard h5f.close()

  let (gain, offset, nodata) = readWhatScaling(h5f, path)
  let stationProj = readProjection(h5f, path)
  let whereGrp = h5f["where".grp_str]
  let extent = projectionExtent(whereGrp, stationProj, path)

  let dset = h5f[RadarDatasetPath.dset_str]
  let dbzData = readScaledDbz(dset, gain, offset, nodata, path)

  let shape = dset.shape
  let rows = shape[0]
  let cols = shape[1]

  # ODIM_H5 IMAGE stores rows origin='upper' (row 0 = north/ymax).
  # We need ascending y for bilinear interp, so flip to row 0 = south.
  var flipped = newTensor[float32]([rows, cols])
  for i in 0 ..< rows:
    let srcRow = rows - 1 - i
    for j in 0 ..< cols:
      flipped[i, j] = dbzData[srcRow, j]

  let ny = rows
  let nx = cols
  var xIn = newSeq[float64](nx)
  var yIn = newSeq[float64](ny)
  for j in 0 ..< nx:
    xIn[j] = extent[0] + (extent[1] - extent[0]) * float64(j) / float64(nx - 1)
  for i in 0 ..< ny:
    yIn[i] = extent[2] + (extent[3] - extent[2]) * float64(i) / float64(ny - 1)

  result = PseudoCappiStation(dbz: flipped, xIn: xIn, yIn: yIn,
                              stationProj: stationProj)
