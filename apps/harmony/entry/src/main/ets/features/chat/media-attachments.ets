import type { media } from '@kit.MediaKit';
import type { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { currentLocale, t } from '../../i18n/i18n';
import { currentScope } from '../../query/query-cache';
import { cachedArtifactPath } from '../../net/artifact-cache';
import type { ArtifactRef } from '../../net/artifact-cache';
import { artifactTypeLabel, fitImageSize, formatFileSize, isAttachmentAudioMimeType, isInlineImageMimeType } from '../../thread/attachments';
import type { AttachmentView } from '../../thread/block-view';
import { AttachmentViewer, saveFile } from './attachment-viewer';

export function localImageUri(path: string): string {
  try {
    return fileUri.getUriFromPath(path);
  } catch (err) {
    return '';
  }
}

/** A raster preview shares the authenticated file cache with the full-screen viewer. */
@ComponentV2
export struct ArtifactImage {
  @Param reference: ArtifactRef = { botId: '', groupId: '', artifactId: '', mimeType: '' };
  @Param name: string = '';
  @Param thumbnail: boolean = false;
  @Local uri: string = '';
  @Local failed: boolean = false;
  @Local imageWidth: number = 1;
  @Local imageHeight: number = 1;
  private loadId: number = 0;
  @Event onTap: () => void = (): void => {};

  aboutToAppear(): void {
    void this.load();
  }

  aboutToDisappear(): void {
    this.loadId += 1;
  }

  @Monitor('reference')
  onReferenceChange(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    const id = ++this.loadId;
    const scope = currentScope();
    this.uri = '';
    this.failed = false;
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) {
        throw new Error('No file context');
      }
      const path = await cachedArtifactPath(context, this.reference);
      if (this.loadId === id && currentScope() === scope) {
        this.uri = localImageUri(path);
        this.failed = !this.uri;
      }
    } catch (err) {
      if (this.loadId === id) {
        this.failed = true;
      }
    }
  }

  build() {
    if (this.uri && !this.failed) {
      Image(this.uri)
        .objectFit(this.thumbnail ? ImageFit.Cover : ImageFit.Contain)
        .width(this.thumbnail ? 32 : this.imageWidth)
        .height(this.thumbnail ? 32 : this.imageHeight)
        .constraintSize({ maxWidth: '100%' })
        .borderRadius(this.thumbnail ? 6 : 10)
        .clip(true)
        .accessibilityLevel(this.thumbnail ? 'no' : 'yes')
        .accessibilityText(this.name)
        .onComplete((event): void => {
          if (event && event.width > 0 && event.height > 0 && !this.thumbnail) {
            const size = fitImageSize(event.width, event.height, 270, 360);
            this.imageWidth = size.width;
            this.imageHeight = size.height;
          }
        })
        .onError((): void => { this.failed = true; })
        .onClick((): void => { this.onTap(); })
    } else if (!this.thumbnail) {
      Row({ space: 8 }) {
        if (!this.failed) {
          LoadingProgress().width(18).height(18).color(appearance.tokens().mutedForeground)
            .accessibilityText(t('Loading image…'))
        }
        Text(this.name || t('Image'))
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().foreground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .padding(10)
      .borderRadius(10)
      .backgroundColor(appearance.tokens().card)
      .onClick((): void => { this.onTap(); })
    }
  }
}

function playbackTime(ms: number): string {
  const total = Number.isFinite(ms) ? Math.max(0, Math.floor(ms / 1000)) : 0;
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

@ComponentV2
struct AudioAttachment {
  @Param reference: ArtifactRef = { botId: '', groupId: '', artifactId: '', mimeType: '' };
  @Param name: string = '';
  @Event onSave: () => void = (): void => {};
  @Local playing: boolean = false;
  @Local loading: boolean = false;
  @Local failed: boolean = false;
  @Local elapsed: number = 0;
  @Local duration: number = 0;
  private active: boolean = true;
  private player: media.AVPlayer | null = null;
  private file: fs.File | null = null;

  aboutToDisappear(): void {
    this.active = false;
    void this.release();
  }

  private async release(): Promise<void> {
    const player = this.player;
    const file = this.file;
    this.player = null;
    this.file = null;
    try {
      await player?.release();
    } catch (err) {
      hilog.warn(0, 'Attachments', 'Could not release the audio player');
    }
    try {
      if (file !== null) {
        await fs.close(file);
      }
    } catch (err) {
      hilog.warn(0, 'Attachments', 'Could not close the audio file');
    }
  }

  private async toggle(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.failed = false;
    try {
      if (this.player === null) {
        const context = this.getUIContext().getHostContext();
        if (!context) {
          throw new Error('No file context');
        }
        const scope = currentScope();
        const path = await cachedArtifactPath(context, this.reference);
        if (!this.active || currentScope() !== scope) {
          return;
        }
        await this.prepare(path, scope);
      } else if (this.player.state === 'playing') {
        await this.player.pause();
      } else {
        await this.player.play();
      }
    } catch (err) {
      this.failed = true;
      this.playing = false;
      await this.release();
    } finally {
      this.loading = false;
    }
  }

  private async prepare(path: string, scope: string): Promise<void> {
    try {
      if (canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
        const api = await import('@ohos.multimedia.media');
        const created = await api.default.createAVPlayer();
        await this.openPlayer(created, path, scope);
      } else {
        this.failed = true;
      }
    } catch (err) {
      await this.release();
      this.failed = true;
    }
  }

  private async openPlayer(player: media.AVPlayer, path: string, scope: string): Promise<void> {
    try {
      if (!this.active || currentScope() !== scope) {
        await player.release();
        return;
      }
      this.player = player;
      this.file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      player.on('stateChange', (state: media.AVPlayerState): void => {
        if (this.player === player) {
          this.playing = state === 'playing';
          if (state === 'initialized') {
            void this.start(player);
          }
        }
      });
      player.on('timeUpdate', (position: number): void => {
        if (this.player === player) {
          this.elapsed = position;
        }
      });
      player.on('error', (): void => { void this.playerFailed(player); });
      player.fdSrc = { fd: this.file.fd };
    } catch (err) {
      await this.release();
      this.failed = true;
    }
  }

  private async start(player: media.AVPlayer): Promise<void> {
    try {
      await player.prepare();
      if (this.player === player) {
        this.duration = player.duration;
        await player.play();
      }
    } catch (err) {
      await this.playerFailed(player);
    }
  }

  private async playerFailed(player: media.AVPlayer): Promise<void> {
    if (this.player === player) {
      this.failed = true;
      this.playing = false;
      await this.release();
    }
  }

  build() {
    Column({ space: 6 }) {
      Text(this.name)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().foreground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 8 }) {
        Button(this.playing ? 'Ⅱ' : '▷', { type: ButtonType.Circle })
          .width(44).height(44)
          .backgroundColor(appearance.tokens().muted)
          .fontColor(appearance.tokens().foreground)
          .accessibilityText(t(this.playing ? 'Pause' : 'Play'))
          .enabled(!this.loading)
          .onClick((): void => { void this.toggle(); })
        Text(`${playbackTime(this.elapsed)} / ${playbackTime(this.duration)}`)
          .fontSize(typeScale.caption.fontSize)
          .fontColor(appearance.tokens().mutedForeground)
          .layoutWeight(1)
        Button('↓', { type: ButtonType.Circle })
          .width(44).height(44)
          .backgroundColor(appearance.tokens().muted)
          .fontColor(appearance.tokens().foreground)
          .accessibilityText(t('Download'))
          .onClick((): void => { this.onSave(); })
      }
      .width('100%')
      if (this.failed) {
        Text(t('Could not play that clip.'))
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().destructive)
      }
    }
    .width('100%')
    .padding(10)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(appearance.tokens().card)
    .borderRadius(12)
  }
}

@ComponentV2
export struct AttachmentBlock {
  @Param view: AttachmentView = { kind: 'image', artifactId: '', name: '', mimeType: '', size: -1 };
  @Param botId: string = '';
  @Param groupId: string = '';
  @Local viewing: boolean = false;
  /** '' when there is nothing to say: "Saved" for a moment, a failure until the next save. */
  @Local saveStatus: string = '';
  @Local saveFailed: boolean = false;
  private saving: boolean = false;
  private mounted: boolean = true;
  private restoreTimer: number = -1;

  aboutToDisappear(): void {
    this.mounted = false;
    clearTimeout(this.restoreTimer);
  }

  /** A file without a preview goes straight to the system save dialog, with no page between. */
  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.saveStatus = '';
    this.saveFailed = false;
    const scope = currentScope();
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      this.viewing = true;
      this.saving = false;
      return;
    }
    const context = host as common.UIAbilityContext;
    let path = '';
    try {
      path = await cachedArtifactPath(context, this.reference);
    } catch (err) {
      // Nothing to save yet: the viewer owns the download and its retry.
      if (this.mounted && scope === currentScope()) {
        this.viewing = true;
      }
      this.saving = false;
      return;
    }
    this.saving = false;
    if (!this.mounted || scope !== currentScope()) {
      return;
    }
    try {
      if (await saveFile(context, path, this.label, this.view.mimeType, scope) && this.mounted) {
        this.saveStatus = t('Saved');
        clearTimeout(this.restoreTimer);
        // Longer than a copy's two seconds: a system dialog has just closed over the row.
        this.restoreTimer = setTimeout((): void => {
          this.saveStatus = '';
        }, 3000);
      }
    } catch (err) {
      if (this.mounted) {
        this.saveFailed = true;
        this.saveStatus = t('Could not save');
      }
    }
  }

  @Computed
  get reference(): ArtifactRef {
    return { botId: this.botId, groupId: this.groupId, artifactId: this.view.artifactId, mimeType: this.view.mimeType };
  }

  @Computed
  get kind(): string {
    const mime = this.view.mimeType.split(';')[0].trim().toLowerCase();
    if (this.view.kind === 'image' && isInlineImageMimeType(mime)) {
      return 'image';
    }
    if (['video/mp4', 'video/quicktime', 'video/3gpp'].includes(mime)) {
      return 'video';
    }
    return mime === 'application/pdf' ? 'pdf' : 'file';
  }

  @Computed
  get label(): string {
    return this.view.name || t(this.view.kind === 'image' ? 'Image' : 'File');
  }

  build() {
    Column() {
      if (this.view.artifactId && this.kind === 'image') {
        ArtifactImage({ reference: this.reference, name: this.label,
          onTap: (): void => { this.viewing = true; } })
      } else if (this.view.artifactId && isAttachmentAudioMimeType(this.view.mimeType)) {
        AudioAttachment({ reference: this.reference, name: this.label,
          onSave: (): void => { void this.save(); } })
      } else {
        Row({ space: 10 }) {
          Text(this.kind === 'video' ? '▷' : (artifactTypeLabel(this.view.mimeType) || '↓'))
            .fontSize(this.kind === 'video' ? typeScale.body.fontSize : typeScale.caption.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
            .accessibilityLevel('no')
          Column({ space: 3 }) {
            Text(this.label)
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().foreground)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.view.size >= 0) {
              Text(formatFileSize(this.view.size, currentLocale()))
                .fontSize(typeScale.caption.fontSize)
                .fontColor(appearance.tokens().mutedForeground)
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(10)
        .backgroundColor(appearance.tokens().card)
        .borderRadius(12)
        .onClick((): void => {
          if (!this.view.artifactId) {
            return;
          }
          if (this.kind === 'file') {
            void this.save();
          } else {
            this.viewing = true;
          }
        })
      }
      if (this.saveStatus) {
        Text(this.saveStatus)
          .fontSize(typeScale.caption.fontSize)
          .fontColor(this.saveFailed ? appearance.tokens().destructive : appearance.tokens().mutedForeground)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .bindContentCover($$this.viewing, this.viewer())
  }

  @Builder
  viewer() {
    AttachmentViewer({ reference: this.reference, name: this.label, kind: this.kind,
      onClose: (): void => { this.viewing = false; } })
  }
}
