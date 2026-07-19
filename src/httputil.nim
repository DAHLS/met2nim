import std/[os, httpclient, json]

# One client reused across all requests (avoids a fresh TLS handshake per
# call). Lazily created; timeout is (re)set per call since the two helpers
# use different defaults.
var sharedClient: HttpClient

proc getClient(timeout: int): HttpClient =
  if sharedClient == nil:
    sharedClient = newHttpClient()
    sharedClient.headers = newHttpHeaders({"User-Agent": "met2img-nim"})
  sharedClient.timeout = timeout
  result = sharedClient

proc errorBody(resp: Response): string =
  # Include a truncated response body in error messages. The DMI/EUMETSAT
  # APIs return useful JSON error payloads; binary bodies are truncated to
  # keep messages readable.
  if resp.body.len == 0:
    return ""
  result = "\n" & resp.body[0 ..< min(resp.body.len, 512)]

# Both helpers retry once by default: a transient 5xx or timeout from the
# APIs would otherwise fail the whole unattended run. `retries` counts the
# extra attempts after the first (0 = fail immediately, used by probes).
const RetryPauseMs = 2000

proc httpGetJson*(url: string, timeout = 60000, retries = 1): JsonNode =
  var lastErr: ref CatchableError
  for attempt in 0 .. retries:
    try:
      let resp = getClient(timeout).get(url)
      if resp.code != Http200:
        raise newException(ValueError, "HTTP GET failed: " & $int(resp.code) &
            " for " & url & errorBody(resp))
      return parseJson(resp.body)
    except CatchableError as e:
      lastErr = e
      if attempt < retries:
        stderr.writeLine("  warning: " & e.msg & " (retrying)")
        sleep(RetryPauseMs)
  raise lastErr

proc httpGetBytes*(url: string, timeout = 120000, retries = 1): string =
  var lastErr: ref CatchableError
  for attempt in 0 .. retries:
    try:
      let resp = getClient(timeout).get(url)
      if resp.code != Http200:
        raise newException(ValueError, "HTTP GET failed: " & $int(resp.code) &
            " for " & url)
      return resp.body
    except CatchableError as e:
      lastErr = e
      if attempt < retries:
        stderr.writeLine("  warning: " & e.msg & " (retrying)")
        sleep(RetryPauseMs)
  raise lastErr
