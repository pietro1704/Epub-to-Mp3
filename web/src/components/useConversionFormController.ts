import type { ConversionFormProps } from './conversion_form_contract';
import { useFormState } from './useFormState';
import { useFormNarrationPolicy } from './useFormNarrationPolicy';
import { useFormUploadSession } from './useFormUploadSession';
import { useFormBookQueue } from './useFormBookQueue';
import { useFormSubmission } from './useFormSubmission';
export type { ConversionFormProps } from './conversion_form_contract';

export function useConversionFormController(props: ConversionFormProps) {
  const state = useFormState();
  const input = { ...state, ...props };
  const narration = useFormNarrationPolicy(input);
  const uploads = useFormUploadSession({ ...input, ...narration });
  const chapters = useFormBookQueue({ ...input, ...narration });
  const submission = useFormSubmission({ ...input, ...narration, ...uploads });
  return { ...input, ...narration, ...uploads, ...chapters, ...submission };
}

export type ConversionFormScope = ReturnType<typeof useConversionFormController>;
