import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import type { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { PdfView, pdfService, pdfViewManager } from '@kit.PDFKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from '../../i18n/i18n';
import { currentScope } from '../../query/query-cache';
import { appearance } from '../../uikit/theme';
import { ActionButton, ErrorText } from '../../uikit/controls';
import { typeScale } from '../../uikit/tokens.generated';
import { attachmentExtensionForMimeType, attachmentStoredName } from '../../thread/attachments';
import { cachedArtifactPath } from '../../net/artifact-cache';
import type { ArtifactRef } from '../../net/artifact-cache';

/** The system "save as" dialog; false when the saver is dismissed without a destination. */
export async function saveFile(context: common.UIAbilityContext, path: string, name: string,
  mimeType: string, scope: string): Promise<boolean> {
  try {
    // The local copy has a safe extension derived from the declared MIME, never from a path.
    const ext = attachmentExtensionForMimeType(mimeType);
    const clean = attachmentStoredName(name, mimeType).replace(/[\\/\u0000-\u001f\u007f]/g, '_').trim();
    const stem = clean.replace(/^\.+/, '').slice(0, 76) || t('File');
    const basename = !ext || stem.toLowerCase().endsWith(ext) ? stem : `${stem}${ext}`;
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [basename];
    const uris = await new picker.DocumentViewPicker(context).save(options);
    if (uris.length === 0 || currentScope() !== scope) {
      return false;
    }
    const dest = await fs.open(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      await fs.copyFile(path, dest.fd);
    } finally {
      await fs.close(dest);
    }
    return true;
  } catch (err) {
    throw new Error(t('Could not save'));
  }
}

@ComponentV2
export struct AttachmentViewer {
  @Param reference: ArtifactRef = { botId: '', groupId: '', artifactId: '', mimeType: '' };
  @Param name: string = '';
  @Param kind: string = '';
  @Event onClose: () => void = (): void => {};
  @Local path: string = '';
  @Local topInset: number = 32;
  @Local loadFailed: boolean = false;
  @Local previewFailed: boolean = false;
  @Local saving: boolean = false;
  @Local saveStatus: string = '';
  @Local saveFailed: boolean = false;
  private pdf: pdfViewManager.PdfController | null = null;
  private active: boolean = false;
  private scope: string = '';
  private restoreTimer: number = -1;

  aboutToAppear(): void {
    this.active = true;
    this.scope = currentScope();
    void this.readInsets();
    void this.load();
  }

  aboutToDisappear(): void {
    this.active = false;
    clearTimeout(this.restoreTimer);
    this.releasePdf();
  }

  private async readInsets(): Promise<void> {
    const ui = this.getUIContext();
    const context = ui.getHostContext();
    if (!context) {
      return;
    }
    try {
      const host = await window.getLastWindow(context);
      const area = host.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      if (this.active) {
        this.topInset = ui.px2vp(area.topRect.height);
      }
    } catch (err) {
      hilog.debug(0, 'Attachments', 'Could not measure the system bars');
    }
  }

  private releasePdf(): void {
    if (this.pdf !== null) {
      try {
        this.pdf.releaseDocument();
      } catch (err) {
        hilog.warn(0, 'Attachments', 'Could not release the PDF document');
      } finally {
        this.pdf = null;
      }
    }
  }

  private async load(): Promise<void> {
    this.loadFailed = false;
    this.previewFailed = false;
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) {
        throw new Error('No file context');
      }
      const path = await cachedArtifactPath(context, this.reference);
      if (!this.active || currentScope() !== this.scope) {
        return;
      }
      if (this.kind === 'pdf' && canIUse('SystemCapability.OfficeService.PDFService.Core')) {
        try {
          const pdf = new pdfViewManager.PdfController();
          this.pdf = pdf;
          const result = await pdf.loadDocument(path);
          if (!this.active || currentScope() !== this.scope) {
            return;
          }
          this.previewFailed = result !== pdfService.ParseResult.PARSE_SUCCESS;
        } catch (err) {
          this.previewFailed = true;
        }
        if (this.previewFailed) {
          this.releasePdf();
        }
      } else if (this.kind === 'pdf') {
        this.previewFailed = true;
      }
      this.path = path;
    } catch (err) {
      if (this.active) {
        this.loadFailed = true;
      }
    }
  }

  private async save(): Promise<void> {
    if (this.saving || currentScope() !== this.scope) {
      return;
    }
    this.saving = true;
    this.saveStatus = '';
    this.saveFailed = false;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path = await cachedArtifactPath(context, this.reference);
      if (this.active && currentScope() === this.scope
        && await saveFile(context, path, this.name, this.reference.mimeType, this.scope) && this.active) {
        this.saveStatus = t('Saved');
        clearTimeout(this.restoreTimer);
        this.restoreTimer = setTimeout((): void => {
          this.saveStatus = '';
        }, 3000);
      }
    } catch (err) {
      this.saveFailed = true;
    } finally {
      this.saving = false;
    }
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize('16vp')
            .fontColor([appearance.tokens().foreground])
        }.width(44).height(44)
          .backgroundColor(appearance.tokens().muted)
          .accessibilityText(t('Close')).onClick((): void => { this.onClose(); })
        Text(this.name)
          .fontSize(typeScale.body.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(appearance.tokens().foreground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // In the header, whose height the buttons fix: a line of its own would move the preview.
        if (this.saveFailed || this.saveStatus) {
          Text(this.saveFailed ? t('Could not save') : this.saveStatus)
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(this.saveFailed ? appearance.tokens().destructive : appearance.tokens().mutedForeground)
            .maxLines(1)
        }
        if (this.path && this.kind !== 'file' && !this.previewFailed) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.arrow_down'))
              .fontSize('16vp')
              .fontColor([appearance.tokens().foreground])
          }.width(44).height(44)
            .backgroundColor(appearance.tokens().muted)
            .accessibilityText(t('Download')).enabled(!this.saving)
            .onClick((): void => { void this.save(); })
        }
      }
      .padding({ left: 12, right: 12, top: this.topInset + 8, bottom: 8 })
      .width('100%')
      if (this.loadFailed) {
        Column({ space: 10 }) {
          ErrorText({ message: t('Could not open file') })
          ActionButton({ label: t('Retry'), kind: 'secondary', onTap: (): void => { void this.load(); } })
        }
        .padding(24)
      } else if (!this.path) {
        LoadingProgress().width(28).height(28).color(appearance.tokens().mutedForeground)
          .accessibilityText(t('Downloading…'))
      } else if (this.kind === 'image' && !this.previewFailed) {
        Image(fileUri.getUriFromPath(this.path))
          .width('100%')
          .layoutWeight(1)
          .objectFit(ImageFit.Contain)
          .accessibilityText(this.name)
          .onError((): void => { this.previewFailed = true; })
      } else if (this.kind === 'video' && !this.previewFailed) {
        Video({ src: fileUri.getUriFromPath(this.path) })
          .width('100%')
          .layoutWeight(1)
          .objectFit(ImageFit.Contain)
          .controls(true)
          .accessibilityText(this.name)
          .onError((): void => { this.previewFailed = true; })
      } else if (this.kind === 'pdf' && this.pdf !== null && !this.previewFailed) {
        PdfView({ controller: this.pdf! }).width('100%').layoutWeight(1)
      } else {
        Column({ space: 12 }) {
          if (this.previewFailed) {
            ErrorText({ message: t(this.kind === 'pdf' ? 'Could not open this PDF.' : 'No preview for this file type.') })
          }
          ActionButton({ label: t('Download'), busy: this.saving, onTap: (): void => { void this.save(); } })
        }
        .padding(24)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(appearance.tokens().background)
  }
}
