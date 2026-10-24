"use strict";
// Mounts the app's puff (PUFF_GLSL from puff.glsl.js) into any canvas on the
// page: the pointer's speed is the level, a click on a puff sends lightning
// through it. A mount can pass `level`, a function returning 0...1 (or null
// for the pointer), to drive its puff from something else (a scripted demo),
// and `tint`, the smoke colour: white by default, near-black over a light app.
// A mount's `disperse` (0...1) breaks the puff up the way the app's exit does.
(function () {
  const FRAG = `#version 300 es
precision highp float;
${PUFF_GLSL}
uniform vec2 uCentre; uniform float uSize; uniform float uTime; uniform float uExpansion;
uniform float uTrail; uniform float uFlow; uniform float uStrike; uniform float uDisperse; uniform vec4 uTint;
out vec4 fragColor;
void main() {
  vec2 p = gl_FragCoord.xy - uCentre; p.y = -p.y;
  fragColor = render(p + 0.5 * vec2(uSize), vec2(uSize), uTime, uExpansion, uTrail, uFlow, uDisperse, uStrike, 1.0, uTint);
}`;
  const VERT = `#version 300 es
in vec2 aPos; void main() { gl_Position = vec4(aPos, 0.0, 1.0); }`;

  class Trail {
    value = 0; last = null;
    constructor(tau) { this.tau = tau; }
    step(e, now) {
      if (this.last === null) { this.last = now; this.value = e; return e; }
      const dt = Math.min(Math.max(now - this.last, 0), 0.1); this.last = now;
      this.value += (e - this.value) * (1 - Math.exp(-dt / this.tau));
      return (this.value = Math.max(this.value, e));
    }
  }
  class Dynamics {
    env = 0; flow = 0; last = null; trail = new Trail(0.8);
    step(level, now) {
      const rest = (l) => 0.44 + 0.35 * Math.min(Math.max(l, 0), 1);
      if (this.last === null) { this.last = now; this.env = level; const e = rest(level); return { e, t: this.trail.step(e, now), f: 0 }; }
      const dt = Math.min(Math.max(now - this.last, 0), 0.1); this.last = now;
      const before = this.env;
      this.env += (level - this.env) * (1 - Math.exp(-dt / (level > this.env ? 0.012 : 0.22)));
      const e = Math.min(1, Math.max(0.05, rest(this.env)));
      this.flow += dt * (0.08 + 6 * Math.max(0, this.env - before));
      return { e, t: this.trail.step(e, now), f: this.flow };
    }
  }

  const pointer = { x: 0, y: 0, t: performance.now(), speed: 0, level: 0, pressed: 0, seen: false };
  addEventListener("pointermove", (ev) => {
    const now = performance.now(), dt = Math.max((now - pointer.t) / 1000, 1 / 240);
    const d = pointer.seen ? Math.hypot(ev.clientX - pointer.x, ev.clientY - pointer.y) : 0;
    pointer.speed += (d / dt - pointer.speed) * 0.12;
    pointer.x = ev.clientX; pointer.y = ev.clientY; pointer.t = now; pointer.seen = true;
  });

  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const start = performance.now();
  const mounts = [];
  let last = start;

  window.mountPuff = function (canvas, opts = {}) {
    const gl = canvas.getContext("webgl2", { alpha: true, premultipliedAlpha: true, antialias: false });
    if (!gl) return;
    const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
    const prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog); gl.useProgram(prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const a = gl.getAttribLocation(prog, "aPos"); gl.enableVertexAttribArray(a); gl.vertexAttribPointer(a, 2, gl.FLOAT, false, 0, 0);
    const u = Object.fromEntries(["uCentre", "uSize", "uTime", "uExpansion", "uTrail", "uFlow", "uStrike", "uDisperse", "uTint"].map((n) => [n, gl.getUniformLocation(prog, n)]));
    const m = { canvas, gl, u, dyn: new Dynamics(), strike: -1, level: opts.level, tint: opts.tint || [1, 1, 1], visible: true };
    canvas.addEventListener("pointerdown", () => { m.strike = (performance.now() - start) / 1000; });
    // A scene's puff starts once its composer is well on screen, not as its edge
    // scrolls in. A mount with `always` decides when it draws by setting `visible`.
    if (!opts.always) new IntersectionObserver(([en]) => { m.visible = en.isIntersecting; }, { rootMargin: "-15% 0px" }).observe(canvas);
    // Lightning, now, for a click the page routes to a puff.
    m.flash = () => { m.strike = (performance.now() - start) / 1000; };
    mounts.push(m);
    return m;
  };

  function draw(m, now, pointerLevel) {
    const { canvas, gl, u } = m;
    const dpr = Math.min(devicePixelRatio || 1, 2);
    const w = Math.round(canvas.clientWidth * dpr), h = Math.round(canvas.clientHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; gl.viewport(0, 0, w, h); }
    const level = (m.level && m.level(now)) ?? pointerLevel;
    const s = reduceMotion ? { e: 0.5, t: 0.5, f: 0 } : m.dyn.step(level, now);
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniform2f(u.uCentre, w / 2, h / 2);
    gl.uniform1f(u.uSize, Math.min(w, h));
    gl.uniform1f(u.uTime, reduceMotion ? 100 : now);
    gl.uniform1f(u.uExpansion, s.e); gl.uniform1f(u.uTrail, s.t); gl.uniform1f(u.uFlow, s.f);
    gl.uniform1f(u.uStrike, reduceMotion ? -1 : m.strike);
    gl.uniform1f(u.uDisperse, m.disperse || 0);
    gl.uniform4f(u.uTint, m.tint[0], m.tint[1], m.tint[2], 1);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  function frame(nowMs) {
    const now = (nowMs - start) / 1000, dt = Math.min((nowMs - last) / 1000, 0.1); last = nowMs;
    if (nowMs - pointer.t > 40) pointer.speed *= Math.exp(-dt / 0.6);
    const target = Math.min(1, pointer.speed / 3200);
    pointer.level += (target - pointer.level) * (1 - Math.exp(-dt / (target > pointer.level ? 0.35 : 0.9)));
    for (const m of mounts) if (m.visible || reduceMotion) draw(m, now, pointer.level);
    if (!reduceMotion) requestAnimationFrame(frame);
  }
  addEventListener("load", () => requestAnimationFrame(frame));
})();
