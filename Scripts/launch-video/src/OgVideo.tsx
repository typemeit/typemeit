import { AbsoluteFill, interpolate, Sequence, useCurrentFrame } from 'remotion';
import { Puff } from './Puff';
import { seconds } from './theme';

// web/og.mp4: web/og.png's four puffs, a wisp growing into a cloud left to
// right, each at rest and drifting as the website's does. The sizes are
// og.png's scaled to 1920 wide, then up until each resting cloud covers what
// it does in the still.

export const ogLoop = seconds(10);
const fade = seconds(2);

const puffs = [
  { x: 0.12, size: 738, offset: 140 },
  { x: 0.34, size: 1168, offset: 150 },
  { x: 0.58, size: 1645, offset: 175 },
  { x: 0.82, size: 2175, offset: 205 },
];

const rest = () => 0;
const white: [number, number, number] = [1, 1, 1];

const Puffs: React.FC = () => (
  <AbsoluteFill style={{ background: '#0e0e0e', overflow: 'hidden' }}>
    {puffs.map((p) => (
      <div key={p.x} style={{ position: 'absolute', left: `${p.x * 100}%`, top: '50%', transform: 'translate(-50%, -50%)' }}>
        <Puff size={p.size} tint={white} level={rest} offset={p.offset} density={1.5} />
      </div>
    ))}
  </AbsoluteFill>
);

// The loop's first two seconds fade from where its last frame leads (the
// puffs 10 s on) into the start, so it plays round without a cut.
export const OgVideo: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill>
      <Puffs />
      {frame < fade ? (
        <Sequence from={-ogLoop} style={{ opacity: interpolate(frame, [0, fade], [1, 0]) }}>
          <Puffs />
        </Sequence>
      ) : null}
    </AbsoluteFill>
  );
};
