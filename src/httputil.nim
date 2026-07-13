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

proc httpGetJson*(url: string, timeout = 60000): JsonNode =
  let resp = getClient(timeout).get(url)
  if resp.code != Http200:
    raise newException(ValueError, "HTTP GET failed: " & $int(resp.code) & " for " & url)
  result = parseJson(resp.body)

proc httpGetBytes*(url: string, timeout = 120000): string =
  let resp = getClient(timeout).get(url)
  if resp.code != Http200:
    raise newException(ValueError, "HTTP GET failed: " & $int(resp.code) & " for " & url)
  result = resp.body
