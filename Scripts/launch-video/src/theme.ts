// The app's own values (TypeMeIt/DesignTokens.swift, Square.swift), in dark
// mode, which is how the pill shows over a dark call.
export const scale = 2;
export const mono = 'ui-monospace, Menlo, monospace';
export const sans = '-apple-system, system-ui, sans-serif';
export const brandMono = 'DM Mono';

export const slab = '#FAFAFA';
export const onSlab = '#0B0B0B';
export const ink = '#FAFAFA';
export const ink2 = '#B4B4B4';

/// The app's cloud colours (TypeMeIt/CloudColor.swift), as the shader's tint,
/// and the website's near-black smoke for a light page (web/scenes.js).
export const tints: Record<string, [number, number, number]> = {
  coral: [0.98, 0.49, 0.4],
  mint: [0.45, 0.85, 0.66],
  sky: [0.42, 0.7, 0.96],
  lavender: [0.66, 0.6, 0.95],
  smoke: [0.08, 0.08, 0.08],
};

export const fps = 30;
export const seconds = (s: number) => Math.round(s * fps);
