import { useReaderPosition, type EbookReaderPanelProps } from './useReaderPosition';
import { EbookReaderPanelView } from './EbookReaderPanelView';

export default function EbookReaderPanel(props: EbookReaderPanelProps): JSX.Element | null {
  const scope = useReaderPosition(props);
  return <EbookReaderPanelView {...scope} />;
}
