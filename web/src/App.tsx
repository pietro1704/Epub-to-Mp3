import { useApplicationWorkspaces, type AppProps } from './useApplicationWorkspaces';
import { AppView } from './AppView';

export default function App(props?: AppProps): JSX.Element {
  const scope = useApplicationWorkspaces(props);
  return <AppView {...scope} />;
}
