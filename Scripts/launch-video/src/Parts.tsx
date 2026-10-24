import { interpolate, useCurrentFrame } from 'remotion';
import { brandMono } from './theme';

/// A burned-in caption: the landing page's lowercase mono on a dark band.
export const Caption: React.FC<{ text: string; from: number; to: number }> = ({ text, from, to }) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [from, from + 6, to - 6, to], [0, 1, 1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  if (frame < from || frame > to) return null;
  return (
    <div
      style={{
        fontFamily: brandMono,
        fontSize: 46,
        color: 'white',
        background: 'rgba(11,11,11,0.82)',
        padding: '14px 28px',
        opacity,
      }}
    >
      {text}
    </div>
  );
};
