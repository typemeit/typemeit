import { useCurrentFrame } from 'remotion';
import { mono, onSlab, scale, slab } from './theme';

// The app's answer pill (TypeMeIt/Overlay/AnswerPill.swift) at `scale`:
// 420 pt wide, a 48 pt row, the mark, the question in mono 13, and the
// stage's buttons; the answer opens under the question.

export type Stage = 'offered' | 'asking' | 'answered';

const px = (points: number) => points * scale;

const Mark: React.FC<{ stage: Stage }> = ({ stage }) => {
  const frame = useCurrentFrame();
  if (stage === 'asking') {
    return (
      <svg width={px(10)} height={px(10)} viewBox="0 0 10 10" style={{ transform: `rotate(${(frame * 12) % 360}deg)` }}>
        <circle cx="5" cy="5" r="4.25" fill="none" stroke={onSlab} strokeOpacity={0.2} strokeWidth="1.5" />
        <path d="M5 0.75 A4.25 4.25 0 0 1 9.25 5" fill="none" stroke={onSlab} strokeWidth="1.5" />
      </svg>
    );
  }
  return <span style={{ fontSize: px(14), color: onSlab, lineHeight: 1 }}>✻</span>;
};

const Button: React.FC<{ primary?: boolean; children: React.ReactNode }> = ({ primary, children }) => (
  <div
    style={{
      height: px(26),
      padding: `0 ${px(10)}px`,
      display: 'flex',
      alignItems: 'center',
      fontFamily: mono,
      fontSize: px(12),
      background: primary ? onSlab : 'transparent',
      color: primary ? slab : onSlab,
    }}
  >
    {children}
  </div>
);

const Cross: React.FC = () => (
  <svg width={px(26)} height={px(26)} viewBox="0 0 26 26">
    <path d="M8 8l10 10M18 8L8 18" stroke={onSlab} strokeWidth="1.2" strokeLinecap="square" />
  </svg>
);

const Chevron: React.FC = () => (
  <svg width={px(26)} height={px(26)} viewBox="0 0 26 26">
    <path d="M8 15l5-5 5 5" fill="none" stroke={onSlab} strokeWidth="1.2" />
  </svg>
);

export const AnswerPill: React.FC<{ question: string; stage: Stage; answer: React.ReactNode; footer: string; answerReveal: number }> = ({
  question,
  stage,
  answer,
  footer,
  answerReveal,
}) => (
  <div
    style={{
      width: px(420),
      background: slab,
      boxShadow: '0 18px 48px rgba(0,0,0,0.45), 0 4px 12px rgba(0,0,0,0.3)',
      overflow: 'hidden',
    }}
  >
    <div style={{ display: 'flex', alignItems: 'center', gap: px(12), padding: `${px(11)}px ${px(10)}px ${px(11)}px ${px(14)}px`, minHeight: px(48), boxSizing: 'border-box' }}>
      <div style={{ width: px(20), display: 'flex', justifyContent: 'center' }}>
        <Mark stage={stage} />
      </div>
      <div style={{ flex: 1, fontFamily: mono, fontSize: px(13), color: onSlab, padding: `0 ${px(6)}px`, lineHeight: 1.3 }}>{question}</div>
      <div style={{ display: 'flex', alignItems: 'center', gap: px(6) }}>
        {stage === 'offered' ? (
          <>
            <Button>no</Button>
            <Button primary>ask claude</Button>
          </>
        ) : null}
        {stage === 'asking' ? <Button primary>open</Button> : null}
        {stage === 'answered' ? (
          <>
            <Chevron />
            <Button primary>open</Button>
          </>
        ) : null}
        {stage !== 'offered' ? <Cross /> : null}
      </div>
    </div>
    {stage === 'answered' ? (
      <div style={{ maxHeight: px(160) * answerReveal, overflow: 'hidden' }}>
        <div style={{ height: 1, background: onSlab, opacity: 0.16 }} />
        <div style={{ padding: `${px(14)}px ${px(16)}px ${px(12)}px ${px(14 + 20 + 12 + 6)}px` }}>
          <div style={{ fontFamily: mono, fontSize: px(12), lineHeight: 1.55, color: onSlab, opacity: 0.92 }}>{answer}</div>
          <div style={{ display: 'flex', alignItems: 'center', marginTop: px(10) }}>
            <div style={{ flex: 1, fontFamily: mono, fontSize: px(10), color: onSlab, opacity: 0.5 }}>{footer}</div>
            <div style={{ fontFamily: mono, fontSize: px(11), color: onSlab, border: `1px solid ${onSlab}`, padding: `${px(3)}px ${px(9)}px` }}>copy</div>
          </div>
        </div>
      </div>
    ) : null}
  </div>
);
