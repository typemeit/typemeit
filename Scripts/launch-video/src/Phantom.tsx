import { useCurrentFrame, useVideoConfig } from 'remotion';
import { brandMono } from './theme';

// The website's phantom words (web/scenes.js `drawWords`): what the puff
// hears drifts up out of it while the line is said, faint and lowercase,
// each word fading in, rising and blurring away. Lengths are in hundredths
// of `width`, as the website's are in container widths.

export type Line = { text: string; from: number; to: number };

const LIFE = 1.7;
const FONT = 1.75;
const RISE = 7;
const FADE_OUT = 0.35;
const jitter = (i: number) => ((Math.sin(i * 12.9898 + 4.1) * 43758.5453) % 1) * 5;

export const Phantom: React.FC<{ line: Line; ink: string; width: number }> = ({ line, ink, width }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const unit = width / 100;
  const speak = (line.to - line.from) / fps;
  const spoken = (frame - line.from) / fps;
  const released = spoken - speak;
  const fade = released > 0 ? Math.max(0, 1 - released / FADE_OUT) : 1;
  const words = line.text.split(' ');
  return (
    <div style={{ position: 'absolute', left: '50%', top: 0, width: 0, height: 0, pointerEvents: 'none' }}>
      {words.map((word, i) => {
        const age = spoken - (0.2 + (i * (speak - 0.6)) / words.length);
        if (age < 0 || age > LIFE || fade === 0) return null;
        const k = age / LIFE;
        return (
          <span
            key={i}
            style={{
              position: 'absolute',
              left: 0,
              bottom: 0,
              whiteSpace: 'nowrap',
              fontFamily: brandMono,
              fontSize: FONT * unit,
              lineHeight: 1,
              letterSpacing: '-0.01em',
              color: `rgb(${ink})`,
              opacity: Math.min(1, age / 0.18) * (1 - k * k) * 0.8 * fade,
              transform: `translate(calc(-50% + ${jitter(i) * unit}px), ${-RISE * unit * (1 - (1 - k) * (1 - k))}px)`,
              filter: `blur(${k * 2.2}px)`,
            }}
          >
            {word}
          </span>
        );
      })}
    </div>
  );
};
