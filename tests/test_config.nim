import unittest
import config

suite "config: colormap":

  test "dbzToRgba boundaries":
    # Below the 5 dBZ floor -> transparent.
    check dbzToRgba(0.0f).a == 0.0f
    check dbzToRgba(4.9f).a == 0.0f
    # At/above floor -> opaque, with a color.
    check dbzToRgba(5.0f).a == 1.0f
    check dbzToRgba(45.0f).a == 1.0f        # red band (45-50)
    check dbzToRgba(77.0f).a == 1.0f        # white (>= 75)
    # NaN -> transparent.
    check dbzToRgba(NaN).a == 0.0f

suite "config: satellite layer mapping":

  test "eumLayer":
    let g = eumLayer(ssGeocolour)
    check g.name == "mtg_fd:rgb_geocolour"
    check g.cadence == 10
    let m = eumLayer(ssEumetsatMsg)
    check m.name == "msg_fes:rgb_naturalenhncd"
    check m.cadence == 15

suite "config: defaults":

  test "defaultConfig":
    let c = defaultConfig()
    check c.collection == ckPseudoCappi
    check c.satSource == ssGeocolour
    check c.minDbz == 10.0f
    check c.zoom == 1.0
    check c.fontPath == ""
