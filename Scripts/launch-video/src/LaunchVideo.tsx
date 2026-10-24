import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { AnswerPill, type Stage } from './AnswerPill';
import { useBrandFonts } from './Fonts';
import { Meet, type Person } from './Meet';
import { Caption } from './Parts';
import { Puff } from './Puff';
import { brandMono, seconds, tints } from './theme';

// 20 s: on a call, Sam asks Max a question; Max holds fn and asks TMI, the
// pill offers it, Enter asks it, the answer comes back in the pill, and Max
// answers Sam without leaving the call.

const question = 'How many calls were there last week?';
const answer = (
  <>
    <b>1,284 calls</b> last week, up 6% on the week before. Counted from the calls table.
  </>
);

const at = {
  samFrom: seconds(0.3),
  samTo: seconds(3.0),
  fnDown: seconds(3.5),
  fnUp: seconds(6.4),
  pill: seconds(6.7),
  enterDown: seconds(8.0),
  answered: seconds(11.4),
  replyFrom: seconds(12.4),
  replyTo: seconds(14.4),
  endCard: seconds(16.4),
};

const people: Person[] = [
  { name: 'Sam Ellis', tile: 'white', tint: tints.sky, offset: 0, lines: [{ text: 'max, do you know how many calls there were last week?', from: at.samFrom, to: at.samTo }] },
  {
    name: 'You',
    tile: 'black',
    tint: tints.lavender,
    offset: 40,
    lines: [
      { text: 'tmi, how many calls were there last week?', from: at.fnDown, to: at.fnUp },
      { text: 'by the way, 1,284', from: at.replyFrom, to: at.replyTo },
    ],
  },
  { name: 'Noor Haddad', tile: 'black', tint: tints.mint, offset: 80, lines: [] },
  { name: 'Ana Ruiz', tile: 'white', tint: tints.coral, offset: 120, lines: [] },
];

const stageAt = (frame: number): Stage => (frame < at.enterDown ? 'offered' : frame < at.answered ? 'asking' : 'answered');

/// SwiftUI's `.spring(duration: 0.46, bounce: 0.1)`, the overlay's
/// (TypeMeIt/Overlay/OverlayPanel.swift), as stiffness and damping for mass 1.
const overlaySpring = { mass: 1, stiffness: ((2 * Math.PI) / 0.46) ** 2, damping: (4 * Math.PI * (1 - 0.1)) / 0.46 };

const restingLevel = () => 0;

const EndCard: React.FC = () => (
  <AbsoluteFill style={{ background: '#ffffff', alignItems: 'center', justifyContent: 'center', gap: 28 }}>
    <div style={{ margin: '-200px 0' }}>
      <Puff size={720} tint={tints.smoke} level={restingLevel} offset={200} />
    </div>
    <div style={{ fontFamily: brandMono, fontSize: 92, color: '#0b0b0b' }}>type me it</div>
    <div style={{ fontFamily: brandMono, fontSize: 40, color: '#4a4a4a' }}>ask claude out loud, on any call</div>
    <div style={{ fontFamily: brandMono, fontSize: 40, color: '#0b0b0b', marginTop: 24 }}>typeme.it</div>
  </AbsoluteFill>
);

export const LaunchVideo: React.FC = () => {
  useBrandFonts();
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  // The pill arrives as the app's overlay does: fading in and growing from
  // 92% at its bottom edge.
  const pillIn = spring({ frame: frame - at.pill, fps, config: overlaySpring });
  const endFade = interpolate(frame, [at.endCard, at.endCard + 12], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

  return (
    <AbsoluteFill>
      <Meet people={people} />

      <AbsoluteFill style={{ alignItems: 'center', paddingTop: 56 }}>
        <Caption text="hold fn and ask claude" from={at.fnDown} to={at.pill + 6} />
        <Caption text="press enter" from={at.pill + 8} to={at.enterDown + 10} />
        <Caption text="answered, mid-call" from={at.answered + 4} to={at.replyFrom} />
      </AbsoluteFill>

      {/* The pill sits at the bottom of the screen, above the call's controls. */}
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'flex-end', paddingBottom: 150 }}>
        {frame >= at.pill ? (
          <div style={{ opacity: pillIn, transform: `scale(${0.92 + 0.08 * pillIn})`, transformOrigin: 'bottom center' }}>
            <AnswerPill question={question} stage={stageAt(frame)} answer={answer} footer="13 s" answerReveal={1} />
          </div>
        ) : null}
      </AbsoluteFill>

      <AbsoluteFill style={{ opacity: endFade }}>{endFade > 0 ? <EndCard /> : null}</AbsoluteFill>
    </AbsoluteFill>
  );
};
