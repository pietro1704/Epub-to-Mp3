import { BrowserConversionClient } from './BrowserConversionClient';
import type { ConversionClient } from './conversion_client_contract';
import { MockConversionClient } from './mock_conversion_client';
export type * from './conversion_client_contract';
export { HttpConversionClient } from './HttpConversionClient';
export { MockConversionClient } from './mock_conversion_client';
export { normalizeErrorMessage, normalizeAssetUrl } from './http_conversion_response';
export { buildFormData as __buildFormData } from './http_conversion_form';

export const conversionClient: ConversionClient = new BrowserConversionClient();
export const mockConversionClient = new MockConversionClient();
