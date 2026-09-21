// Serves the site from ./web, and answers two paths of its own:
//
//   /download              streams the latest release's DMG from GitHub under
//                          the name "type me it.dmg". The asset on GitHub is
//                          TypeMeIt.dmg: /releases/latest/download/ only
//                          resolves a fixed name, and GitHub replaces spaces
//                          in asset names with dots, so the name the visitor
//                          saves has to be set here, in Content-Disposition.
//   /share/note/<name>     PUT leaves a sealed drop, GET collects it once.
//
// A drop is bytes this server cannot read. The key comes from ten characters
// of the code that go from one person to the other and are never sent here;
// what is sent here is the eight that name the drop, and those say nothing
// about the other ten. So holding every drop in the bucket is not a way into
// any of them.
const DMG = "https://github.com/typemeit/typemeit/releases/latest/download/TypeMeIt.dmg";

// The name a drop goes under. The app draws it from an alphabet with no I, L,
// O, 0 or 1 in it, because a code gets read off one screen and typed into
// another.
const NAME = /^\/share\/note\/([ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8})$/;

// Notes are text, and half a megabyte of it is more than anyone hands over in
// one go. The app caps itself at the same number.
const LIMIT = 512 * 1024;

// Long enough for someone to pass a code along, short enough that a drop
// nobody collected is not sitting about. A collected drop goes at once.
const LIFETIME = 10 * 60 * 1000;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/download") return download();
    const drop = url.pathname.match(NAME);
    if (drop) {
      if (request.method === "PUT") return leave(request, env, drop[1]);
      if (request.method === "GET") return collect(env, drop[1]);
      return new Response("no", { status: 405, headers: { Allow: "PUT, GET" } });
    }
    return env.ASSETS.fetch(request);
  },
};

async function download() {
  const upstream = await fetch(DMG, { redirect: "follow" });
  if (!upstream.ok) return new Response("the download is not available right now", { status: 502 });
  const headers = new Headers({
    "Content-Type": "application/x-apple-diskimage",
    "Content-Disposition": 'attachment; filename="type me it.dmg"',
    "Cache-Control": "no-store",
  });
  const length = upstream.headers.get("Content-Length");
  if (length) headers.set("Content-Length", length);
  return new Response(upstream.body, { status: 200, headers });
}

async function leave(request, env, name) {
  const body = await request.arrayBuffer();
  if (body.byteLength === 0 || body.byteLength > LIMIT) {
    return new Response("that is not a drop", { status: 413 });
  }
  // Names are drawn at random by the app, so this is not a thing that
  // happens; it is here so that if it ever did, the drop already waiting
  // would not be quietly replaced by the new one.
  if (await env.NOTES.head(name)) {
    return new Response("that name is taken", { status: 409 });
  }
  await env.NOTES.put(name, body, {
    customMetadata: { expires: String(Date.now() + LIFETIME) },
    httpMetadata: { contentType: "application/octet-stream" },
  });
  return new Response(null, { status: 201, headers: { "Cache-Control": "no-store" } });
}

async function collect(env, name) {
  const drop = await env.NOTES.get(name);
  if (!drop) return missing();

  // A drop is good for one collection. Deleting before answering means a
  // request that dies halfway cannot be retried into a second read of
  // something that was meant to be read once.
  await env.NOTES.delete(name);

  // The bucket's own clean-up runs to a rule measured in days, so the ten
  // minutes are kept here, where they can be counted in milliseconds.
  const expires = Number(drop.customMetadata?.expires ?? 0);
  if (!expires || Date.now() > expires) return missing();

  return new Response(drop.body, {
    status: 200,
    headers: { "Content-Type": "application/octet-stream", "Cache-Control": "no-store" },
  });
}

/// Never left, already collected, or the ten minutes are up. The three are
/// one answer on purpose: which it was would tell someone working through
/// names that they had found one.
function missing() {
  return new Response("nothing there", { status: 404, headers: { "Cache-Control": "no-store" } });
}
