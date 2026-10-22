import { ConversionFormValues, ConversionState, SubmitBatchOptions } from '../types/conversion';
import { type UploadResponse } from '../services/ConversionService';

export interface ConversionFormProps {
  isSubmitting: boolean;
  onSubmit: (values: ConversionFormValues, options?: SubmitBatchOptions) => Promise<void> | void;
  onUploadFile: (file: File) => Promise<UploadResponse>;
  onSubmitIntent?: () => void;
  onUploadStateChange?: (pendingUploads: number) => void;
  currentJob?: {
    jobId?: string;
    phase: ConversionState['phase'];
    bookTitle?: string | null;
    engine?: string;
    voice?: string;
    language?: string;
    formattingCues?: boolean;
    noParallel?: boolean;
    multiEngineParallel?: boolean;
  };
}
