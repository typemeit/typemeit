import { useCallback } from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from 'remotion';
import { type Line, Phantom } from './Phantom';
import { Puff, voiceLevel } from './Puff';
import { sans } from './theme';

// A video call in the style of Google Meet's dark theme: a grid of people,
// the call's details and its controls. Every name is invented.

export type { Line } from './Phantom';

/// A person on the call: their tile, their puff's colour (the app's cloud
/// colours, TypeMeIt/CloudColor.swift) and what they say.
export type Person = { name: string; tile: 'black' | 'white'; tint: [number, number, number]; offset: number; lines: Line[] };

/// The width the website's word lengths are hundredths of: its scene is a
/// whole app window, which here is about the video's width.
const sceneWidth = 1600;
const puffSize = 600;

const Tile: React.FC<{ person: Person }> = ({ person }) => {
  const { fps } = useVideoConfig();
  const dark = person.tile === 'black';
  // Speaking while one of their lines is being said, at the website's level.
  const level = useCallback(
    (t: number) => {
      const line = person.lines.find((spoken) => t >= spoken.from / fps && t < spoken.to / fps);
      return line ? voiceLevel(t - line.from / fps) : 0;
    },
    [person.lines, fps],
  );
  return (
    <div
      style={{
        position: 'relative',
        borderRadius: 16,
        background: dark ? '#0b0b0b' : '#fafafa',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        overflow: 'hidden',
      }}
    >
      <div style={{ position: 'relative' }}>
        <Puff size={puffSize} tint={person.tint} level={level} offset={person.offset} />
        {/* The words rise from just above the puff's centre, where the website's do. */}
        <div style={{ position: 'absolute', left: 0, right: 0, top: puffSize * 0.38 }}>
          {person.lines.map((line) => (
            <Phantom key={line.from} line={line} ink={dark ? '240, 240, 240' : '20, 20, 20'} width={sceneWidth} />
          ))}
        </div>
      </div>
      <div style={{ position: 'absolute', left: 20, bottom: 16, color: dark ? '#fafafa' : '#0b0b0b', fontFamily: sans, fontSize: 24, fontWeight: 500 }}>
        {person.name}
      </div>
    </div>
  );
};

const RoundButton: React.FC<{ red?: boolean; wide?: boolean; children: React.ReactNode }> = ({ red, wide, children }) => (
  <div
    style={{
      width: wide ? 112 : 64,
      height: 64,
      borderRadius: 32,
      background: red ? '#ea4335' : '#3c4043',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
    }}
  >
    {children}
  </div>
);

const icon = { width: 30, height: 30, fill: 'none', stroke: 'white', strokeWidth: 2, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };

export const Meet: React.FC<{ people: Person[] }> = ({ people }) => {
  const frame = useCurrentFrame();
  const minutes = 42 + Math.floor(frame / 1800);
  return (
    <AbsoluteFill style={{ background: '#202124' }}>
      <div
        style={{
          position: 'absolute',
          inset: '24px 24px 120px 24px',
          display: 'grid',
          gridTemplateColumns: '1fr 1fr',
          gridTemplateRows: '1fr 1fr',
          gap: 16,
          opacity: interpolate(frame, [0, 8], [0, 1], { extrapolateRight: 'clamp' }),
        }}
      >
        {people.map((person) => (
          <Tile key={person.name} person={person} />
        ))}
      </div>
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          bottom: 0,
          height: 120,
          display: 'flex',
          alignItems: 'center',
          padding: '0 36px',
          fontFamily: sans,
          color: 'white',
        }}
      >
        <div style={{ flex: 1, fontSize: 24 }}>
          10:{minutes} &nbsp;|&nbsp; abc-defg-hij
        </div>
        <div style={{ display: 'flex', gap: 14 }}>
          <RoundButton>
            <svg {...icon} viewBox="0 0 24 24"><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5 11a7 7 0 0 0 14 0M12 18v3" /></svg>
          </RoundButton>
          <RoundButton>
            <svg {...icon} viewBox="0 0 24 24"><rect x="3" y="6" width="13" height="12" rx="2" /><path d="M16 10l5-3v10l-5-3z" /></svg>
          </RoundButton>
          <RoundButton>
            <svg {...icon} viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M7 15h4M13 15h4M7 11h10" /></svg>
          </RoundButton>
          <RoundButton>
            <svg {...icon} viewBox="0 0 24 24"><path d="M8 13V6a1.5 1.5 0 0 1 3 0v5M11 11V4.5a1.5 1.5 0 0 1 3 0V11M14 11V6a1.5 1.5 0 0 1 3 0v7a6 6 0 0 1-6 6h-1a6 6 0 0 1-5-3l-2-4a1.5 1.5 0 0 1 2.5-1.5L8 13" /></svg>
          </RoundButton>
          <RoundButton>
            <svg {...icon} viewBox="0 0 24 24"><circle cx="5" cy="12" r="1" /><circle cx="12" cy="12" r="1" /><circle cx="19" cy="12" r="1" /></svg>
          </RoundButton>
          <RoundButton red wide>
            <svg {...icon} viewBox="0 0 24 24"><path d="M3 14c5-5 13-5 18 0l-2 3-4-2v-3a10 10 0 0 0-6 0v3l-4 2z" fill="white" /></svg>
          </RoundButton>
        </div>
        <div style={{ flex: 1 }} />
      </div>
    </AbsoluteFill>
  );
};
