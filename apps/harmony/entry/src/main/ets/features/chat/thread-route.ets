import type { ShareContent } from '../../thread/incoming-share';

export interface ThreadRoute {
  botId: string;
  groupId: string;
  title: string;
  /** The Space the chat was opened in (A2): the page closes when the selection leaves it. */
  spaceId?: string;
  share?: ShareContent;
}
