"use strict";
// Plays dictation over the App Store scenes: while fn is held the puff
// speaks and the words it hears drift up out of it, faint and lowercase, as
// spoken; on release the composer swaps from empty to typed in one go, tidied,
// the way the app pastes. Markup:
//   <div class="scene" data-scenes="slack claude">
//     <img class="empty"><img class="typed"><canvas class="puff"></canvas>
//   </div>
// A scene plays by itself while its puff is on screen. Buttons with
// data-for="<scene id>" data-scene="slack" switch scene, and a
// <kbd data-for="<scene id>"> goes down while the scene speaks.
(function () {
  const TINT = { slack: [0.08, 0.08, 0.08], claude: [1, 1, 1] };
  const INK = { slack: "20, 20, 20", claude: "240, 240, 240" };
  // What was said, before Apple Intelligence tidied it into the typed scene.
  const SAID = {
    slack: "leaving in ten i'll grab a bottle of red on the way over",
    claude: "build me a minimal transcription app for the mac make no mistakes",
  };
  const IDLE = 0.3, SPEAK = 3.6, TRANSCRIBE = 0.15, SHOW = 1.8;
  // Scenes whose message is sent HOLD seconds after it is typed: it joins the
  // thread and the composer empties, from shots/<name>-sent.webp.
  const SENDS = { slack: true };
  const HOLD = 0.8;
  const CYCLE = IDLE + SPEAK + TRANSCRIBE + SHOW;
  // A word fades in, rises RISE container-widths over LIFE seconds, and goes.
  const LIFE = 1.7, RISE = 7, FADE_OUT = 0.35;
  // The caret baked into each shot, in shot pixels (2000 x 1254): its x and
  // top and bottom y, empty and typed, and the composer colour that hides it.
  const SHOT_W = 2000, SHOT_H = 1254;
  const CARET = {
    slack: { empty: [439, 1141, 1161], typed: [852, 1141, 1161], paper: "#fff" },
    claude: { empty: [790, 524, 550], typed: [1455, 525, 550], paper: "rgb(31, 31, 31)" },
  };
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Each word leaves the cloud a little left or right of the last, the same
  // way every cycle.
  const jitter = (i) => ((Math.sin(i * 12.9898 + 4.1) * 43758.5453) % 1) * 5;

  class Scene {
    constructor(el) {
      this.el = el;
      this.names = el.dataset.scenes.split(" ");
      // Kept decoded, so a scene switch paints the new shots in the same frame.
      this.shots = [];
      for (const n of this.names) for (const v of SENDS[n] ? ["empty", "typed", "sent"] : ["empty", "typed"]) {
        const img = new Image();
        img.src = `shots/${n}-${v}.webp`;
        img.decode().catch(() => {});
        this.shots.push(img);
      }
      this.empty = el.querySelector(".empty");
      this.typed = el.querySelector(".typed");
      this.sent = el.querySelector(".sent");
      for (const img of [this.empty, this.typed, this.sent]) img.decoding = "sync";
      this.phantom = Object.assign(document.createElement("div"), { className: "phantom" });
      this.phantom.setAttribute("aria-hidden", "true");
      el.appendChild(this.phantom);
      // Covers the shot's caret every other half second, so it blinks.
      this.blink = Object.assign(document.createElement("div"), { className: "blink" });
      this.blink.setAttribute("aria-hidden", "true");
      el.appendChild(this.blink);
      this.tabs = [...document.querySelectorAll(`[data-for="${el.id}"][data-scene]`)];
      this.pinned = false;
      this.cycles = 0;
      this.onShow = null;
      for (const t of this.tabs) t.addEventListener("click", () => { this.pinned = true; this.show(t.dataset.scene); this.restart = true; });
      this.show(this.names[0]);
    }

    get tint() { return TINT[this.current]; }

    show(name) {
      this.current = name;
      // A cut, not a fade: fading the sent message out would show it back in
      // the composer for a moment before the next scene.
      for (const img of [this.typed, this.sent]) img.style.transition = "none";
      this.typed.style.opacity = this.sent.style.opacity = 0;
      void this.el.offsetWidth;
      for (const img of [this.typed, this.sent]) img.style.transition = "";
      this.empty.src = `shots/${name}-empty.webp`;
      this.typed.src = `shots/${name}-typed.webp`;
      if (SENDS[name]) this.sent.src = `shots/${name}-sent.webp`;
      this.phantom.style.color = `rgb(${INK[name]})`;
      this.phantom.replaceChildren(...SAID[name].split(" ").map((w) => Object.assign(document.createElement("span"), { textContent: w })));
      this.words = [...this.phantom.children];
      for (const t of this.tabs) t.setAttribute("aria-pressed", String(t.dataset.scene === name));
      this.blink.style.background = CARET[name].paper;
      this.caretAt("empty");
      this.phase = -1;
      this.onShow?.(name);
    }

    /** Moves the blink over the caret of the empty or the typed shot. */
    caretAt(shot) {
      if (shot === this.caretShot) return;
      this.caretShot = shot;
      const [x, top, bottom] = CARET[this.current][shot];
      Object.assign(this.blink.style, {
        left: `${((x - 3) / SHOT_W) * 100}%`,
        top: `${((top - 3) / SHOT_H) * 100}%`,
        width: `${(7 / SHOT_W) * 100}%`,
        height: `${((bottom - top + 7) / SHOT_H) * 100}%`,
      });
    }

    /** Back to the empty composer, no words. */
    rest() {
      this.typed.style.opacity = reduceMotion ? 1 : 0;
      this.sent.style.opacity = 0;
      for (const w of this.words) w.style.opacity = 0;
      this.caretAt(reduceMotion ? "typed" : "empty");
      this.phase = -1;
    }

    /**
     * Where the dictation is `t` seconds into its cycles: sets the composer
     * and the words, and returns the puff's level and the phase (0 waiting,
     * 1 speaking, 2 transcribing, 3 typed).
     */
    step(t) {
      const n = Math.floor(t / CYCLE);
      if (n !== this.cycles) {
        this.cycles = n;
        // Each cycle moves to the next scene, until someone picks one.
        if (!this.pinned && this.names.length > 1) this.show(this.names[(this.names.indexOf(this.current) + 1) % this.names.length]);
      }
      t -= n * CYCLE;
      const p = t < IDLE ? 0 : t < IDLE + SPEAK ? 1 : t < IDLE + SPEAK + TRANSCRIBE ? 2 : 3;
      if (p !== this.phase) { this.phase = p; this.typed.style.opacity = p === 3 ? 1 : 0; }
      const sent = SENDS[this.current] && t >= IDLE + SPEAK + TRANSCRIBE + HOLD;
      this.sent.style.opacity = sent ? 1 : 0;
      this.caretAt(p === 3 && !sent ? "typed" : "empty");
      this.drawWords(t);
      if (p !== 1) return { level: 0, phase: p };
      const s = Math.sin(t * 11) * 0.5 + Math.sin(t * 7.3 + 1) * 0.35 + Math.sin(t * 17) * 0.25;
      return { level: Math.max(0, 0.25 + s * 0.6), phase: p };
    }

    drawWords(t) {
      const spoken = t - IDLE;
      const released = spoken - SPEAK;
      const fade = released > 0 ? Math.max(0, 1 - released / FADE_OUT) : 1;
      this.words.forEach((span, i) => {
        const age = spoken - (0.2 + i * (SPEAK - 0.6) / this.words.length);
        if (age < 0 || age > LIFE || fade === 0) { span.style.opacity = 0; return; }
        const k = age / LIFE;
        span.style.opacity = (Math.min(1, age / 0.18) * (1 - k * k) * 0.8 * fade).toFixed(3);
        span.style.transform = `translate(calc(-50% + ${jitter(i).toFixed(2)}cqw), ${(-RISE * (1 - (1 - k) * (1 - k))).toFixed(2)}cqw)`;
        span.style.filter = `blur(${(k * 2.2).toFixed(2)}px)`;
      });
    }
  }
  for (const el of document.querySelectorAll(".scene")) {
    const canvas = el.querySelector(".puff");
    if (!canvas) continue;
    const scene = new Scene(el);
    if (reduceMotion) { scene.rest(); continue; }
    let start = null, drawn = 0;
    const keys = document.querySelectorAll(`kbd[data-for="${el.id}"]`);
    const puff = mountPuff(canvas, {
      tint: scene.tint,
      level(now) {
        // Back on screen after a while away, it starts over rather than
        // picking up mid-cycle with the message already typed.
        if (start === null || scene.restart || now - drawn > 0.5) { start = now; scene.restart = false; scene.cycles = 0; scene.rest(); }
        drawn = now;
        const { level, phase } = scene.step(now - start);
        canvas.style.opacity = phase === 1 || phase === 2 ? 1 : 0;
        for (const k of keys) k.classList.toggle("down", phase === 1);
        return level;
      },
    });
    scene.onShow = (name) => { puff.tint = TINT[name]; };
  }
})();
