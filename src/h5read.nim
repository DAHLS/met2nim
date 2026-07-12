import std/[strutils, options]
import nimhdf5
import arraymancer
import geo

type
  RadarField* = object
    dbz*: Tensor[float32]
    extent*: Extent     # [xmin, xmax, ymin, ymax] in projection metres
    proj*: Projection

proc failH5*(path, msg: string) =
  raise newException(ValueError, "Radar file '" & path & "': " & msg)

proc readAttrF64*(grp: H5Group, name: string, path: string): float64 =
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

proc readAttrStr*(grp: H5Group, name: string, path: string): string =
  result = grp.attrs[name, string]

proc readAttrStrF64*(grp: H5Group, name: string, path: string): string =
  result = readAttrStr(grp, name, path)
  result = result.strip()

proc parseRadarH5*(path: string): RadarField =
  let h5f = H5open(path, "r")
  defer: discard h5f.close()

  let whatGrp = h5f["what".grp_str]
  let whereGrp = h5f["where".grp_str]

  let gain = readAttrF64(whatGrp, "gain", path)
  let offset = readAttrF64(whatGrp, "offset", path)
  let nodata = readAttrF64(whatGrp, "nodata", path)

  let projdef = readAttrStr(whereGrp, "projdef", path)
  let proj = parseProjdef(projdef)

  let cornerKeys = [("LL_lon", "LL_lat"), ("LR_lon", "LR_lat"),
                    ("UL_lon", "UL_lat"), ("UR_lon", "UR_lat")]
  var
    xmin = Inf
    xmax = -Inf
    ymin = Inf
    ymax = -Inf
  for (klon, klat) in cornerKeys:
    let lon = readAttrF64(whereGrp, klon, path)
    let lat = readAttrF64(whereGrp, klat, path)
    let (x, y) = proj.forward(lat, lon)
    xmin = min(xmin, x)
    xmax = max(xmax, x)
    ymin = min(ymin, y)
    ymax = max(ymax, y)

  let dset = h5f["dataset1/data1/data".dset_str]
  let shape = dset.shape
  let rows = shape[0]
  let cols = shape[1]
  let dtypeKind = dset.dtypeAnyKind

  # Read raw data and convert to float32 reflectivity.
  var dbzData = newTensor[float32]([rows, cols])
  case dtypeKind
  of dkUInt8:
    let raw = dset.read(uint8)
    for i in 0 ..< rows:
      for j in 0 ..< cols:
        let v = raw[i * cols + j]
        if float64(v) == nodata:
          dbzData[i, j] = NaN.float32
        else:
          dbzData[i, j] = float32(gain * float64(v) + offset)
  of dkInt16:
    let raw = dset.read(int16)
    for i in 0 ..< rows:
      for j in 0 ..< cols:
        let v = raw[i * cols + j]
        if float64(v) == nodata:
          dbzData[i, j] = NaN.float32
        else:
          dbzData[i, j] = float32(gain * float64(v) + offset)
  of dkInt8:
    let raw = dset.read(int8)
    for i in 0 ..< rows:
      for j in 0 ..< cols:
        let v = raw[i * cols + j]
        if float64(v) == nodata:
          dbzData[i, j] = NaN.float32
        else:
          dbzData[i, j] = float32(gain * float64(v) + offset)
  else:
    failH5(path, "unexpected dataset dtype: " & $dtypeKind)

  result = RadarField(
    dbz: dbzData,
    extent: (xmin, xmax, ymin, ymax),
    proj: proj,
  )

type
  PseudoCappiStation* = object
    dbz*: Tensor[float32]     # rows 0 = south (flipped from file)
    xIn*: seq[float64]        # ascending x grid coords (station projection)
    yIn*: seq[float64]        # ascending y grid coords (station projection)
    stationProj*: Projection

proc readPseudoCappiStation*(path: string): PseudoCappiStation =
  let h5f = H5open(path, "r")
  defer: discard h5f.close()

  let whatGrp = h5f["what".grp_str]
  let whereGrp = h5f["where".grp_str]

  let gain = readAttrF64(whatGrp, "gain", path)
  let offset = readAttrF64(whatGrp, "offset", path)
  let nodata = readAttrF64(whatGrp, "nodata", path)

  let projdef = readAttrStr(whereGrp, "projdef", path)
  let stationProj = parseProjdef(projdef)

  let cornerKeys = [("LL_lon", "LL_lat"), ("LR_lon", "LR_lat"),
                    ("UL_lon", "UL_lat"), ("UR_lon", "UR_lat")]
  var
    xmin = Inf
    xmax = -Inf
    ymin = Inf
    ymax = -Inf
  for (klon, klat) in cornerKeys:
    let lon = readAttrF64(whereGrp, klon, path)
    let lat = readAttrF64(whereGrp, klat, path)
    let (x, y) = stationProj.forward(lat, lon)
    xmin = min(xmin, x)
    xmax = max(xmax, x)
    ymin = min(ymin, y)
    ymax = max(ymax, y)

  let dset = h5f["dataset1/data1/data".dset_str]
  let shape = dset.shape
  let rows = shape[0]
  let cols = shape[1]
  let dtypeKind = dset.dtypeAnyKind

  var dbzData = newTensor[float32]([rows, cols])
  case dtypeKind
  of dkUInt8:
    let raw = dset.read(uint8)
    for i in 0 ..< rows:
      for j in 0 ..< cols:
        let v = raw[i * cols + j]
        if float64(v) == nodata:
          dbzData[i, j] = NaN.float32
        else:
          dbzData[i, j] = float32(gain * float64(v) + offset)
  of dkInt16:
    let raw = dset.read(int16)
    for i in 0 ..< rows:
      for j in 0 ..< cols:
        let v = raw[i * cols + j]
        if float64(v) == nodata:
          dbzData[i, j] = NaN.float32
        else:
          dbzData[i, j] = float32(gain * float64(v) + offset)
  else:
    failH5(path, "unexpected dataset dtype: " & $dtypeKind)

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
    xIn[j] = xmin + (xmax - xmin) * float64(j) / float64(nx - 1)
  for i in 0 ..< ny:
    yIn[i] = ymin + (ymax - ymin) * float64(i) / float64(ny - 1)

  result = PseudoCappiStation(
    dbz: flipped,
    xIn: xIn,
    yIn: yIn,
    stationProj: stationProj,
  )
