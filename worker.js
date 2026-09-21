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
///
/// The sockets are hibernatable. A share is two people reading a code to each
/// other and a few frames at the end of it, so nearly all of a room's life is
/// spent with nothing happening; hibernation is what stops that wait being
/// billed as wall-clock time, and it is the difference between paying for the
/// conversation and paying for the silence around it. It also means the room
/// is not holding its sockets in a variable: `getWebSockets()` is the list,
/// and it survives the object being evicted and brought back.
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
  }

  async fetch() {
    if (this.state.getWebSockets().length >= 2) {
      // Somebody is already talking here. This is the shape a guessed or
      // reused code takes, and the two who are in stay undisturbed.
      return new Response("that code is in use", { status: 409 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.state.acceptWebSocket(server);
    await this.state.storage.setAlarm(Date.now() + ShareRoom.LIFETIME);

    // How many are here counting this one, so the Mac that joined second
    // knows the other is already waiting.
    const peers = this.state.getWebSockets().length;
    server.send(JSON.stringify({ t: "room", peers }));
    if (peers === 2) this.pass(server, JSON.stringify({ t: "peer" }));
    return new Response(null, { status: 101, webSocket: client });
  }

  /// A Mac's frames are binary and go to the other Mac untouched. Nothing
  /// here reads them: what they carry is between the two ends, and a server
  /// that parsed them would be a server that could change them.
  ///
  /// Text from a Mac is dropped rather than passed on. This room's own
  /// messages are text, so forwarding a Mac's would let one end pose as the
  /// room to the other.
  webSocketMessage(from, message) {
    if (typeof message === "string") return;
    if (message.byteLength > ShareRoom.LIMIT) return;
    this.pass(from, message);
  }

  webSocketClose(from) {
    this.pass(from, JSON.stringify({ t: "gone" }));
  }

  webSocketError(from) {
    this.pass(from, JSON.stringify({ t: "gone" }));
  }

  pass(from, body) {
    for (const socket of this.state.getWebSockets()) {
      if (socket === from) continue;
      try {
        socket.send(body);
      } catch {
        // A socket that has gone is dealt with by its own close event.
      }
    }
  }

  /// The room's time is up.
  async alarm() {
    for (const socket of this.state.getWebSockets()) {
      try {
        socket.close(1000, "the code expired");
      } catch {
        // Already gone.
      }
    }
  }
}
