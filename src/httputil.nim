import std/[httpclient, json]

proc httpGetJson*(url: string, timeout = 60000): JsonNode =
  let client = newHttpClient(timeout = timeout)
  client.headers = newHttpHeaders({"User-Agent": "met2img-nim"})
  try:
    result = parseJson(client.getContent(url))
  finally:
    client.close()

proc httpGetBytes*(url: string, timeout = 120000): string =
  let client = newHttpClient(timeout = timeout)
  client.headers = newHttpHeaders({"User-Agent": "met2img-nim"})
  try:
    result = client.getContent(url)
  finally:
    client.close()
