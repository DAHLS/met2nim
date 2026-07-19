import unittest
import std/[json, times]
import config, radar

proc mkFeature(id, href, dt: string): JsonNode =
  ## Build a minimal radardata API feature. Empty href omits the asset's
  ## href key; empty dt omits the datetime property.
  result = newJObject()
  if id.len > 0:
    result["id"] = newJString(id)
  var asset = newJObject()
  if href.len > 0:
    asset["data"] = %*{"href": href}
  result["asset"] = asset
  var props = newJObject()
  if dt.len > 0:
    props["datetime"] = newJString(dt)
  result["properties"] = props

suite "radar: extractFeature":

  test "data asset href":
    let it = extractFeature(mkFeature("a.h5", "http://x/a.h5",
        "2026-07-19T01:00:00Z"))
    check it.fname == "a.h5"
    check it.href == "http://x/a.h5"
    check it.dtIso == "2026-07-19T01:00:00Z"

  test "flat href asset":
    let f = parseJson("""{"id": "b.h5", "asset": {"href": "http://x/b.h5"},
      "properties": {"datetime": "2026-07-19T01:00:00Z"}}""")
    check extractFeature(f).href == "http://x/b.h5"

  test "data asset without href key yields empty href (no KeyError)":
    let it = extractFeature(mkFeature("c.h5", "", "2026-07-19T01:00:00Z"))
    check it.fname == "c.h5"
    check it.href == ""

  test "missing id raises":
    expect ValueError:
      discard extractFeature(mkFeature("", "http://x/d.h5",
          "2026-07-19T01:00:00Z"))

suite "radar: pickNewestScan":
  const
    t1 = "2026-07-19T01:00:00Z"
    t2 = "2026-07-19T02:00:00Z" # newer than t1

  test "most stations wins, even over a newer scan":
    let feats = %*[
      mkFeature("n1.h5", "http://x/n1.h5", t2),
      mkFeature("n2.h5", "http://x/n2.h5", t2),
      mkFeature("o1.h5", "http://x/o1.h5", t1),
      mkFeature("o2.h5", "http://x/o2.h5", t1),
      mkFeature("o3.h5", "http://x/o3.h5", t1),
    ]
    let si = pickNewestScan(feats, "pseudoCappi")
    check si.items.len == 3
    check si.dtIso == t1

  test "tie favours the newest":
    let feats = %*[
      mkFeature("n1.h5", "http://x/n1.h5", t2),
      mkFeature("n2.h5", "http://x/n2.h5", t2),
      mkFeature("o1.h5", "http://x/o1.h5", t1),
      mkFeature("o2.h5", "http://x/o2.h5", t1),
    ]
    let si = pickNewestScan(feats, "pseudoCappi")
    check si.items.len == 2
    check si.dtIso == t2
    check si.scanDt == parseIsoUtc(t2)

  test "features without href or datetime are excluded":
    let feats = %*[
      mkFeature("n1.h5", "", t2), # no href
      mkFeature("n2.h5", "http://x/n2.h5", ""), # no datetime
      mkFeature("o1.h5", "http://x/o1.h5", t1),
    ]
    let si = pickNewestScan(feats, "pseudoCappi")
    check si.items.len == 1
    check si.dtIso == t1

  test "empty feature list raises":
    expect ValueError:
      discard pickNewestScan(newJArray(), "pseudoCappi")

  test "no usable feature raises":
    expect ValueError:
      discard pickNewestScan(%*[mkFeature("n1.h5", "", t2)], "pseudoCappi")
