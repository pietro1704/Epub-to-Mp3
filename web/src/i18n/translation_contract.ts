import type {
  ActiveConversionText,
  FormText,
  ProgressQueueText,
} from './translation_conversion_types';
import type {
  StatusText,
  ResumableJobsText,
  RecentJobsText,
  DownloadsText,
} from './translation_status_types';
import type {
  TopBarText,
  HeroText,
  TabsText,
  LayoutText,
  FlowMessages,
} from './translation_layout_types';

export type Locale = 'en' | 'pt';

export interface Translations {
  locale: Locale;
  topBar: TopBarText;
  hero: HeroText;
  tabs: TabsText;
  activeConversion: ActiveConversionText;
  form: FormText;
  status: StatusText;
  resumableJobs: ResumableJobsText;
  recentJobs: RecentJobsText;
  downloads: DownloadsText;
  layout: LayoutText;
  flow: FlowMessages;
  queue: ProgressQueueText;
}
