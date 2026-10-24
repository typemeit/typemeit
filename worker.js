// Serves the site from ./web, and the release files from the typemeit-releases
// R2 bucket, whose keys are the URL paths:
//
//   /appcast.xml                 Sparkle's feed (SUFeedURL)
//   /releases/<tag>/TypeMeIt.dmg the DMG each appcast entry points at
//   /models/<file>               the speech and speaker models the app downloads
//   /download                    the latest DMG, key TypeMeIt.dmg, saved as "type me it.dmg"
//
// Range and conditional requests are passed to R2, so an interrupted model
// download resumes instead of starting over.
const RELEASE_PATH = /^\/(appcast\.xml|releases\/[^/]+\/[^/]+|models\/[^/]+)$/;
const LATEST_DMG = "TypeMeIt.dmg";

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/download") {
      const response = await serve(request, env, LATEST_DMG);
      if (response.ok) response.headers.set("Content-Disposition", 'attachment; filename="type me it.dmg"');
      return response;
    }
    if (RELEASE_PATH.test(pathname)) return serve(request, env, pathname.slice(1));
    return env.ASSETS.fetch(request);
  },
};

async function serve(request, env, key) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const object = request.method === "HEAD"
    ? await env.RELEASES.head(key)
    : await env.RELEASES.get(key, { range: request.headers, onlyIf: request.headers });
  if (object === null) return new Response("not found", { status: 404 });

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Accept-Ranges", "bytes");
  if (request.method === "HEAD") {
    headers.set("Content-Length", String(object.size));
    return new Response(null, { status: 200, headers });
  }
  // A failed If-None-Match / If-Modified-Since returns the metadata with no body.
  if (!("body" in object)) return new Response(null, { status: 304, headers });
  if (object.range && request.headers.has("Range")) {
    const { offset: start, length: count, suffix } = object.range;
    const offset = suffix !== undefined ? object.size - suffix : start ?? 0;
    const length = suffix ?? count ?? object.size - offset;
    headers.set("Content-Range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    return new Response(object.body, { status: 206, headers });
  }
  return new Response(object.body, { status: 200, headers });
}
