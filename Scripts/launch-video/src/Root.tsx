import { Composition } from 'remotion';
import { LaunchVideo } from './LaunchVideo';
import { OgVideo, ogLoop } from './OgVideo';
import { fps, seconds } from './theme';

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition id="AskClaude" component={LaunchVideo} durationInFrames={seconds(20)} fps={fps} width={1920} height={1080} />
      <Composition id="OgVideo" component={OgVideo} durationInFrames={ogLoop} fps={fps} width={1920} height={1008} />
    </>
  );
};
