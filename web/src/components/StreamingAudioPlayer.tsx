import { useChapterStreamSession, type StreamingAudioPlayerProps } from './useChapterStreamSession';
import { StreamingAudioPlayerView } from './StreamingAudioPlayerView';

export default function StreamingAudioPlayer(props: StreamingAudioPlayerProps): JSX.Element | null {
  const scope = useChapterStreamSession(props);
  return <StreamingAudioPlayerView {...scope} />;
}
