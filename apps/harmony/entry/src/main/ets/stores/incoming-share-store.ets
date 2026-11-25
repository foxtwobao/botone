import type { Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { currentSessionGeneration } from '../net/session';
import { SHARE_MAX_AGE_MS, shareContent } from '../thread/incoming-share';
import type { ShareRecord, ShareContent } from '../thread/incoming-share';

@ObservedV2
export class IncomingShareStore {
  @Trace pending: ShareContent | null = null;
  private version: number = 0;
  private expiration: number = -1;

  cancel(): void {
    this.version += 1;
    if (this.expiration !== -1) {
      clearTimeout(this.expiration);
      this.expiration = -1;
    }
    this.pending = null;
  }

  take(): ShareContent | null {
    const share = this.pending;
    this.cancel();
    return share;
  }

  async receive(want: Want): Promise<void> {
    if (want.action !== 'ohos.want.action.sendData') {
      return;
    }
    this.cancel();
    const version = this.version;
    const session = currentSessionGeneration();
    try {
      const shared = await systemShare.getSharedData(want);
      if (version !== this.version || session !== currentSessionGeneration()) {
        return;
      }
      const records: ShareRecord[] = shared.getRecords().map((record: systemShare.SharedRecord): ShareRecord => ({
        uri: record.uri, name: record.title, mimeType: fileMime(record.utd), content: record.content,
      }));
      const share = shareContent(records);
      if (share.text || share.files.length) {
        this.pending = share;
        this.expiration = setTimeout((): void => this.cancel(), SHARE_MAX_AGE_MS);
      }
    } catch (err) {
      hilog.warn(0, 'Attachments', 'Could not read the system share');
    }
  }
}

function fileMime(utd: string): string | undefined {
  try {
    return uniformTypeDescriptor.getTypeDescriptor(utd).mimeTypes[0];
  } catch (err) {
    return undefined;
  }
}

export const incomingShare = new IncomingShareStore();
