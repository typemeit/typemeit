// Serves the site from ./web, and answers two paths of its own:
//
//   /download           streams the latest release's DMG from GitHub under the
//                       name "type me it.dmg". The asset on GitHub is
//                       TypeMeIt.dmg: /releases/latest/download/ only resolves a
//                       fixed name, and GitHub replaces spaces in asset names
//                       with dots, so the name the visitor saves has to be set
//                       here, in the Content-Disposition header.
//   /share/room/<id>    a websocket into the room two Macs share notes through.
//
// The room passes sealed bytes between two Macs and has no key for them. The
// key the two ends agree is derived partly from the pairing code, and what
// reaches this server is only that code's SHA-256, so it can tell one pair of
// Macs from another without being able to read what they send or to stand in
// the middle of them agreeing it.
const DMG = "https://github.com/typemeit/typemeit/releases/latest/download/TypeMeIt.dmg";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/download") return download();
    const room = url.pathname.match(/^\/share\/room\/([0-9a-f]{64})$/);
    if (room) return join(request, env, room[1]);
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

function join(request, env, id) {
  if (request.headers.get("Upgrade") !== "websocket") {
    return new Response("expected a websocket", { status: 426 });
  }
  return env.ROOMS.get(env.ROOMS.idFromName(id)).fetch(request);
}

/// Two Macs, and the sealed frames that go between them.
export class ShareRoom {
  // A share takes under a minute. Ten is room for someone reading a code down
  // a phone line; after that the room is closed whatever state it is in, so a
  // room cannot be left open to be walked into later.
  static LIFETIME = 10 * 60 * 1000;
  // What one frame is allowed to be. The app caps itself well under this; a
  // message past it is not one of ours.
  static LIMIT = 1024 * 1024;

  constructor(state) {
    this.state = state;
    this.sockets = [];
  }

  async fetch() {
    if (this.sockets.length >= 2) {
      // Somebody is already talking here. This is the shape a guessed or
      // reused code takes, and the two who are in stay undisturbed.
      return new Response("that code is in use", { status: 409 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    this.sockets.push(server);
    await this.state.storage.setAlarm(Date.now() + ShareRoom.LIFETIME);

    server.addEventListener("message", (event) => this.relay(server, event.data));
    server.addEventListener("close", () => this.left(server));
    server.addEventListener("error", () => this.left(server));

    // How many are here counting this one, so the Mac that joined second
    // knows the other is already waiting.
    server.send(JSON.stringify({ t: "room", peers: this.sockets.length }));
    if (this.sockets.length === 2) this.tell(server, { t: "peer" });
    return new Response(null, { status: 101, webSocket: client });
  }

  /// A Mac's frames are binary and go to the other Mac untouched. Nothing
  /// here reads them: what they carry is between the two ends, and a server
  /// that parsed them would be a server that could change them.
  ///
  /// Text from a Mac is dropped rather than passed on. This room's own
  /// messages are text, so forwarding a Mac's would let one end pose as the
  /// room to the other.
  relay(from, data) {
    if (typeof data === "string") return;
    if (!(data instanceof ArrayBuffer) || data.byteLength > ShareRoom.LIMIT) return;
    this.pass(from, data);
  }

  /// One of the room's own messages, as text.
  tell(from, message) {
    this.pass(from, JSON.stringify(message));
  }

  pass(from, body) {
    for (const socket of this.sockets) {
      if (socket === from) continue;
      try {
        socket.send(body);
      } catch {
        // A socket that has gone is dealt with by its own close event.
      }
    }
  }

  left(socket) {
    this.sockets = this.sockets.filter((s) => s !== socket);
    this.tell(null, { t: "gone" });
  }

  /// The room's time is up.
  async alarm() {
    for (const socket of this.sockets) {
      try {
        socket.close(1000, "the code expired");
      } catch {
        // Already gone.
      }
    }
    this.sockets = [];
  }
}
