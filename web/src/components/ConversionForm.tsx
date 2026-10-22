import {
  useConversionFormController,
  type ConversionFormProps,
} from './useConversionFormController';
import { ConversionFormView } from './ConversionFormView';

export default function ConversionForm(props: ConversionFormProps): JSX.Element {
  const scope = useConversionFormController(props);
  return <ConversionFormView {...scope} />;
}
