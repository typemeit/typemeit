// Copies the website's shader (web/puff.glsl.js, generated from the app's
// TypeMeIt/Overlay/Puff.metal) into the video as a module, so the video's
// puff is the app's puff. Runs before the studio and every render.
import { readFileSync, writeFileSync } from 'node:fs';

const source = readFileSync(new URL('../../../web/puff.glsl.js', import.meta.url), 'utf8');
writeFileSync(new URL('../src/puff.glsl.ts', import.meta.url), source.replace('const PUFF_GLSL', 'export const PUFF_GLSL'));
