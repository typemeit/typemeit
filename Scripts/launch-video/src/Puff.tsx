import { useLayoutEffect, useRef } from 'react';
import { useCurrentFrame, useVideoConfig } from 'remotion';
import { PUFF_GLSL } from './puff.glsl';

// The website's puff (web/puff-hero.js), which is the app's: Puff.metal's
// shader through WebGL2, with its expansion, trail and flow from the same
// envelope. The website steps that envelope on the page's clock; here it is
// stepped from the start of the video to the frame, so a frame always renders
// the same.

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

/// The step the envelope is integrated at: the website's display refresh.
const step = 1 / 60;

/// puff-hero.js's Dynamics and Trail, run from 0 to `now` seconds.
const envelope = (level: (t: number) => number, now: number) => {
  const rest = (l: number) => 0.44 + 0.35 * Math.min(Math.max(l, 0), 1);
  let env = level(0);
  let expansion = rest(env);
  let trail = expansion;
  let flow = 0;
  for (let t = step; t <= now + 1e-9; t += step) {
    const target = level(t);
    const before = env;
    env += (target - env) * (1 - Math.exp(-step / (target > env ? 0.012 : 0.22)));
    expansion = Math.min(1, Math.max(0.05, rest(env)));
    flow += step * (0.08 + 6 * Math.max(0, env - before));
    trail += (expansion - trail) * (1 - Math.exp(-step / 0.8));
    trail = Math.max(trail, expansion);
  }
  return { expansion, trail, flow };
};

/// scenes.js's speaking level while a line is being said, `t` seconds into it.
export const voiceLevel = (t: number) => {
  const s = Math.sin(t * 11) * 0.5 + Math.sin(t * 7.3 + 1) * 0.35 + Math.sin(t * 17) * 0.25;
  return Math.max(0, 0.25 + s * 0.6);
};

type Gl = { gl: WebGL2RenderingContext; uniforms: Record<string, WebGLUniformLocation | null> };

export const Puff: React.FC<{
  size: number;
  /// The smoke's colour, 0...1 per channel, as the app's cloud colours.
  tint: [number, number, number];
  /// The speaking level at `t` seconds into the video, 0...1.
  level: (t: number) => number;
  /// Seconds added to the shader's clock, so puffs side by side differ.
  offset?: number;
  /// The tint's alpha: past 1 it saturates the dense cores, as og.png's do.
  density?: number;
}> = ({ size, tint, level, offset = 0, density = 1 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const canvas = useRef<HTMLCanvasElement>(null);
  const context = useRef<Gl | null>(null);

  useLayoutEffect(() => {
    if (!canvas.current) return;
    if (!context.current) {
      const gl = canvas.current.getContext('webgl2', { alpha: true, premultipliedAlpha: true, antialias: false, preserveDrawingBuffer: true });
      if (!gl) return;
      const shader = (type: number, source: string) => {
        const compiled = gl.createShader(type)!;
        gl.shaderSource(compiled, source);
        gl.compileShader(compiled);
        return compiled;
      };
      const program = gl.createProgram()!;
      gl.attachShader(program, shader(gl.VERTEX_SHADER, VERT));
      gl.attachShader(program, shader(gl.FRAGMENT_SHADER, FRAG));
      gl.linkProgram(program);
      gl.useProgram(program);
      gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const position = gl.getAttribLocation(program, 'aPos');
      gl.enableVertexAttribArray(position);
      gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
      const names = ['uCentre', 'uSize', 'uTime', 'uExpansion', 'uTrail', 'uFlow', 'uStrike', 'uDisperse', 'uTint'];
      context.current = { gl, uniforms: Object.fromEntries(names.map((name) => [name, gl.getUniformLocation(program, name)])) };
    }
    const { gl, uniforms } = context.current;
    const now = frame / fps;
    const shape = envelope(level, now);
    gl.viewport(0, 0, size, size);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniform2f(uniforms.uCentre, size / 2, size / 2);
    gl.uniform1f(uniforms.uSize, size);
    gl.uniform1f(uniforms.uTime, now + offset);
    gl.uniform1f(uniforms.uExpansion, shape.expansion);
    gl.uniform1f(uniforms.uTrail, shape.trail);
    gl.uniform1f(uniforms.uFlow, shape.flow);
    gl.uniform1f(uniforms.uStrike, -1);
    gl.uniform1f(uniforms.uDisperse, 0);
    gl.uniform4f(uniforms.uTint, tint[0], tint[1], tint[2], density);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }, [frame, fps, level, offset, size, tint, density]);

  return <canvas ref={canvas} width={size} height={size} style={{ width: size, height: size, display: 'block' }} />;
};
