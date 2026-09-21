// Serves the site from ./web, and answers three paths of its own:
//
//   /download           streams the latest release's DMG from GitHub under the
//                       name "type me it.dmg". The asset on GitHub is
//                       TypeMeIt.dmg: /releases/latest/download/ only resolves a
//                       fixed name, and GitHub replaces spaces in asset names
//                       with dots, so the name the visitor saves has to be set
//                       here, in the Content-Disposition header.
//   /share/ice          the ICE servers the app should use to find a path
//                       between two Macs.
//   /share/room/<id>    a websocket into the room two Macs meet in to swap the
//                       WebRTC offer, answer and candidates that get them
//                       connected to each other.
//
// The room carries nothing else. Once the two Macs have a path, the notes go
// directly between them and never come back here; and even the messages that
// do pass through say only how to reach a Mac, never what is being sent.
const DMG = "https://github.com/typemeit/typemeit/releases/latest/download/TypeMeIt.dmg";

// Free, and enough on its own for most pairs: it tells a Mac how the world
// sees it, which is what the other end needs to aim at.
const STUN = { urls: ["stun:stun.cloudflare.com:3478"] };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/download") return download();
    if (url.pathname === "/share/ice") return ice(env);
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

// Two Macs behind ordinary home routers reach each other with STUN alone. Two
// behind the stricter kind -- carrier-grade NAT, some corporate networks --
// cannot, and need a relay to pass the traffic through. That relay is
// Cloudflare's TURN, which is only offered when the account has been set up
// for it; without it the app still works for most pairs and says so plainly
// when a connection cannot be made.
async function ice(env) {
  const servers = [STUN];
  if (env.TURN_KEY_ID && env.TURN_API_TOKEN) {
    try {
      const response = await fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.TURN_API_TOKEN}`,
            "Content-Type": "application/json",
          },
          // Long enough to cover a share, short enough that a credential
          // taken off one Mac is worth little.
          body: JSON.stringify({ ttl: 3600 }),
        },
      );
      if (response.ok) {
        const body = await response.json();
        for (const server of body.iceServers ?? []) {
          if (server.username) servers.push(server);
        }
      }
    } catch {
      // A relay we could not mint is a share that may still work without one.
    }
  }
  return Response.json({ iceServers: servers }, { headers: { "Cache-Control": "no-store" } });
}

function join(request, env, id) {
  if (request.headers.get("Upgrade") !== "websocket") {
    return new Response("expected a websocket", { status: 426 });
  }
  return env.ROOMS.get(env.ROOMS.idFromName(id)).fetch(request);
}

/// Two Macs, and the messages that introduce them to each other.
///
/// The room is named after the SHA-256 of the code one of them showed the
/// other, so what reaches this server is a hash and never the code itself: it
/// can tell two Macs apart without being able to join them.
export class ShareRoom {
  // A share takes under a minute. Ten is room for someone reading a code down
  // a phone line; after that the room is closed whatever state it is in, so a
  // room cannot be left open to be walked into later.
  static LIFETIME = 10 * 60 * 1000;

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
    // knows not to wait before it starts.
    server.send(JSON.stringify({ t: "room", peers: this.sockets.length }));
    if (this.sockets.length === 2) this.tell(server, { t: "peer" });
    return new Response(null, { status: 101, webSocket: client });
  }

  /// Messages go to the other socket untouched. Nothing here reads them: what
  /// they carry is between the two Macs, and a server that parsed it would be
  /// a server that could change it.
  relay(from, data) {
    if (typeof data !== "string" || data.length > 64 * 1024) return;
    this.tell(from, data);
  }

  tell(from, message) {
    const body = typeof message === "string" ? message : JSON.stringify(message);
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
