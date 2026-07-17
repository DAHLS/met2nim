import unittest
import std/[times]
import config, lightning

proc mkTime(minsFromEpoch: int64): Time =
  fromUnix(0) + initDuration(minutes = minsFromEpoch)

suite "lightning: opacity (linear fade, 0% at 3h)":

  test "fresh strike is 100%":
    check abs(lightningOpacity(0.0) - 1.0) <= 1e-6

  test "1.5h is 50%":
    check abs(lightningOpacity(1.5) - 0.5) <= 1e-6

  test "1h is ~66.7%":
    check abs(lightningOpacity(1.0) - (1.0 - 1.0 / 3.0)) <= 1e-6

  test "2h is ~33.3%":
    check abs(lightningOpacity(2.0) - (1.0 - 2.0 / 3.0)) <= 1e-6

  test "just under 3h is still >0%":
    check lightningOpacity(2.999) > 0.0

  test "exactly 3h is 0%":
    check abs(lightningOpacity(3.0) - 0.0) <= 1e-6

  test "negative age clamps to 100%":
    check abs(lightningOpacity(-1.0) - 1.0) <= 1e-6

suite "lightning: mergeAndPrune":

  test "dedup by id across overlap":
    var cache = LightningCache(lastFetch: mkTime(1000),
      strikes: @[LightningStrike(id: "a", lon: 10.0, lat: 56.0, observed: mkTime(950))])
    let fetched = @[LightningStrike(id: "a", lon: 10.0, lat: 56.0, observed: mkTime(950)),
                    LightningStrike(id: "b", lon: 11.0, lat: 56.0, observed: mkTime(1050))]
    mergeAndPrune(cache, fetched, mkTime(1100), didFetch = true)
    check cache.strikes.len == 2
    check cache.lastFetch == mkTime(1100)

  test "prune strikes older than the 3h window ending at scanTime":
    let scanTime = mkTime(10000)
    let cutoff = scanTime - initDuration(hours = int(LightningWindowHours))
    var cache = LightningCache(lastFetch: mkTime(9900),
      strikes: @[
        LightningStrike(id: "old",  lon: 10.0, lat: 56.0, observed: cutoff - initDuration(seconds = 1)),
        LightningStrike(id: "keep", lon: 10.0, lat: 56.0, observed: cutoff + initDuration(seconds = 1)),
        LightningStrike(id: "new",  lon: 10.0, lat: 56.0, observed: mkTime(9950)),
      ])
    mergeAndPrune(cache, @[], scanTime, didFetch = false)
    check cache.strikes.len == 2
    check cache.strikes[0].id == "keep"
    check cache.strikes[1].id == "new"
    # didFetch=false must not advance lastFetch.
    check cache.lastFetch == mkTime(9900)

  test "didFetch=true advances lastFetch to scanTime":
    var cache = LightningCache(lastFetch: mkTime(1000), strikes: @[])
    mergeAndPrune(cache, @[], mkTime(5000), didFetch = true)
    check cache.lastFetch == mkTime(5000)

  test "empty cache + empty fetched stays empty":
    var cache = LightningCache()
    mergeAndPrune(cache, @[], mkTime(1000), didFetch = true)
    check cache.strikes.len == 0
    check cache.lastFetch == mkTime(1000)
