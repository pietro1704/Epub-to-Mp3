import { useChapterProgress, type ChapterProgressListProps } from './useChapterProgress';
import { ChapterProgressListView } from './ChapterProgressListView';

export default function ChapterProgressList(props: ChapterProgressListProps): JSX.Element | null {
  const scope = useChapterProgress(props);
  return <ChapterProgressListView {...scope} />;
}
