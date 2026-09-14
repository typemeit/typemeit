// Serves the site from ./web, and answers /download by streaming the latest
// release's DMG from GitHub under the name "type me it.dmg". The asset on GitHub
// is typemeit.dmg: /releases/latest/download/ only resolves a fixed name, and
// GitHub replaces spaces in asset names with dots, so the name the visitor saves
// has to be set here, in the Content-Disposition header.
const LATEST = "https://github.com/typemeit/typemeit/releases/latest/download/";
// Releases up to the rename named the asset TypeMeIt.dmg, and the latest
// release is whatever is out there now, so the old name is tried second.
const NAMES = ["typemeit.dmg", "TypeMeIt.dmg"];

async function fetchDmg() {
  for (const name of NAMES) {
    const upstream = await fetch(LATEST + name, { redirect: "follow" });
    if (upstream.ok) return upstream;
  }
  return null;
}

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== "/download") return env.ASSETS.fetch(request);
    const upstream = await fetchDmg();
    if (!upstream) return new Response("the download is not available right now", { status: 502 });
    const headers = new Headers({
      "Content-Type": "application/x-apple-diskimage",
      "Content-Disposition": 'attachment; filename="type me it.dmg"',
      "Cache-Control": "no-store",
    });
    const length = upstream.headers.get("Content-Length");
    if (length) headers.set("Content-Length", length);
    return new Response(upstream.body, { status: 200, headers });
  },
};
