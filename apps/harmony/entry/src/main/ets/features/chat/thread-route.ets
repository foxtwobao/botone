import type { ShareContent } from '../../thread/incoming-share';

export interface ThreadRoute {
  botId: string;
  groupId: string;
  title: string;
  share?: ShareContent;
}
