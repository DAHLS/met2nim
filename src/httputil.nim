import std/[httpclient, json]

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

proc httpGetJson*(url: string, timeout = 60000): JsonNode =
  let resp = getClient(timeout).get(url)
  if resp.code != Http200:
    raise newException(ValueError, "HTTP GET failed: " & $int(resp.code) &
        " for " & url & errorBody(resp))
  result = parseJson(resp.body)

proc httpGetBytes*(url: string, timeout = 120000): string =
  let resp = getClient(timeout).get(url)
  if resp.code != Http200:
    raise newException(ValueError, "HTTP GET failed: " & $int(resp.code) &
        " for " & url)
  result = resp.body
