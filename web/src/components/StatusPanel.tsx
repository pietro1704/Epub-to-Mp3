import { useConversionStatus, type StatusPanelProps } from './useConversionStatus';
import { StatusPanelView } from './StatusPanelView';

export default function StatusPanel(props: StatusPanelProps): JSX.Element {
  const scope = useConversionStatus(props);
  return <StatusPanelView {...scope} />;
}

export { formatEta } from '../utils/formatEta';
