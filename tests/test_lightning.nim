import unittest
import std/[times]
import config, lightning

proc mkTime(minsFromEpoch: int64): Time =
  fromUnix(0) + initDuration(minutes = minsFromEpoch)

suite "lightning: opacity aging (2.4h step, -10% per step, 0% at 24h)":

  test "fresh strike is 100%":
    check abs(lightningOpacity(0.0) - 1.0) <= 1e-6

  test "just under a step is still 100%":
    check abs(lightningOpacity(2.399) - 1.0) <= 1e-6

  test "exactly one step is 90%":
    check abs(lightningOpacity(2.4) - 0.9) <= 1e-6

  test "6h sits in the 80% band (3 steps)":
    check abs(lightningOpacity(6.0) - 0.8) <= 1e-6

  test "6h just before next step still 80%":
    check abs(lightningOpacity(7.199) - 0.8) <= 1e-6

  test "23.9h is 10% (10th step before rollover)":
    check abs(lightningOpacity(23.9) - 0.1) <= 1e-6

  test "exactly 24h is 0%":
    check abs(lightningOpacity(24.0) - 0.0) <= 1e-6

  test "negative age clamps to 100%":
    check abs(lightningOpacity(-1.0) - 1.0) <= 1e-6

suite "lightning: mergeAndPrune":

  test "dedup by id across overlap":
    var cache = LightningCache(lastFetch: mkTime(1000),
      strikes: @[LightningStrike(id: "a", lon: 10.0, lat: 56.0, observed: mkTime(900))])
    let fetched = @[LightningStrike(id: "a", lon: 10.0, lat: 56.0, observed: mkTime(900)),
                    LightningStrike(id: "b", lon: 11.0, lat: 56.0, observed: mkTime(1050))]
    mergeAndPrune(cache, fetched, mkTime(1100), didFetch = true)
    check cache.strikes.len == 2
    check cache.lastFetch == mkTime(1100)

  test "prune strikes older than the 24h window ending at scanTime":
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

  test "dedup tolerates a large re-fetch of the same ids":
    var cache = LightningCache(lastFetch: mkTime(0))
    for i in 0 ..< 50:
      cache.strikes.add(LightningStrike(id: "s" & $i, lon: 10.0, lat: 56.0,
                                        observed: mkTime(1000 + int64(i))))
    var fetched: seq[LightningStrike] = @[]
    for i in 0 ..< 50:
      fetched.add(LightningStrike(id: "s" & $i, lon: 10.0, lat: 56.0,
                                  observed: mkTime(1000 + int64(i))))
    fetched.add(LightningStrike(id: "s50", lon: 10.0, lat: 56.0, observed: mkTime(1100)))
    mergeAndPrune(cache, fetched, mkTime(1100), didFetch = true)
    check cache.strikes.len == 51
