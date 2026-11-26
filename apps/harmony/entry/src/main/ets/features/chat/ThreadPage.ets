// ThreadPage (design §6.5/§7.2 M3): the open chat. List + LazyForEach over the store's rows
// (day separators, message bubbles, the live progress bubble), history paging on top-reach,
// the composer with send/retry, stop while a run works, ask answers through the same consent
// gate, and markRead on open/foreground/new-message. The screen expresses intent; the store and
// stream own orchestration. Copy reuses catalog msgids; the one placeholder string is centralized.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ListSource } from '../../uikit/list-source';
import { ErrorText } from '../../uikit/controls';
import { currentLocale, t } from '../../i18n/i18n';
import type { common } from '@kit.AbilityKit';
import { currentScope } from '../../query/query-cache';
import { subscribeSession, subscribeSpaceSelection } from '../../net/session';
import { attachmentMaxBytes, attachmentMaxCount } from '../../thread/attachments';
import { importAttachmentSources, pickAttachmentSources, removeTemporaryFile } from '../../thread/attachment-files';
import type { AttachmentSource, DraftAttachment } from '../../thread/attachment-files';
import { THREAD_MESSAGE_TEXT_MAX_LENGTH } from '../../thread/thread-send';
import { ComposerAttachments, ComposerReplyPreview } from './composer-attachments';
import { app } from '../../app/app-state';
import { ThreadStore, daySeparatorLabel } from '../../stores/thread-store';
import type { ThreadRow } from '../../stores/thread-store';
import { RosterHolder } from '../../realtime/roster-holder';
import { MessageBubble } from './MessageBubble';
import { installConsentDialog } from './consent-dialog';
import type { LiveMessage } from '../../thread/thread-snapshot';
import type { ShareContent } from '../../thread/incoming-share';
import type { ThreadRoute } from './thread-route';

const COMPOSER_CONTROL_SIZE = 46;

@ComponentV2
export struct ThreadPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Param botId: string = '';
  @Param groupId: string = '';
  @Param title: string = '';
  @Param route: ThreadRoute | null = null;
  @Local store: ThreadStore = new ThreadStore();
  @Local source: ListSource<ThreadRow> = new ListSource<ThreadRow>([]);
  @Local draft: string = '';
  @Local attachments: DraftAttachment[] = [];
  @Local attachmentNotice: string = '';
  @Local picking: boolean = false;
  private active: boolean = false;
  private scope: string = '';
  private offSession: (() => void) | null = null;
  private offSpace: (() => void) | null = null;
  /** M6: the parent whose id the next send carries. Kept on failure for a safe retry. */
  @Local replyTarget: LiveMessage | null = null;
  private holder: RosterHolder = new RosterHolder();

  @Monitor('store.sentRevision')
  onSent(): void {
    this.clearDraft();
    // A taller composer (attachments, progress) shrinks the list while the send runs, which turns
    // "at the bottom" off without a scroll. A sender lands on the message they just sent.
    this.atBottom = true;
    this.scroller.scrollEdge(Edge.Bottom);
  }

  @Computed
  get canSend(): boolean {
    return !this.picking && !this.store.send.pending && (!!this.draft.trim() || this.attachments.length > 0);
  }

  @Computed
  get room(): number {
    return Math.max(0, attachmentMaxCount(app.me) - this.attachments.length);
  }

  private offChanges: (() => void) | null = null;
  private offConsent: (() => void) | null = null;
  private scroller: Scroller = new Scroller();
  private atBottom: boolean = true;

  aboutToAppear(): void {
    this.active = true;
    this.scope = currentScope();
    this.offSession = subscribeSession((): void => this.sessionChanged());
    this.offSpace = subscribeSpaceSelection((): void => this.sessionChanged());
    this.offConsent = installConsentDialog();
    this.offChanges = this.store.subscribeChanges((): void => {
      this.source.reload(this.store.rows);
      if (this.atBottom) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    });
    this.store.open(this.botId, this.groupId, app.me?.userId ?? '');
    this.store.setVisible(true);
    this.source.reload(this.store.rows);
    this.holder.start();
    const share = this.route?.share;
    if (share !== undefined) {
      this.route!.share = undefined;
      this.draft = share.text;
      if (share.files.length) {
        void this.importShare(share);
      }
    }
  }

  aboutToDisappear(): void {
    this.active = false;
    this.offSession?.();
    this.offSpace?.();
    this.clearDraft();
    this.store.setVisible(false);
    this.store.close();
    this.offChanges?.();
    this.offChanges = null;
    this.offConsent?.();
    this.offConsent = null;
    this.holder.stop();
  }

  private clearDraft(): void {
    for (const item of this.attachments) {
      removeTemporaryFile(item.path);
    }
    this.attachments = [];
    this.draft = '';
    this.replyTarget = null;
    this.attachmentNotice = '';
  }

  private sessionChanged(): void {
    if (this.scope !== currentScope()) {
      this.store.close();
      this.clearDraft();
      this.stack.clear();
    }
  }

  private async importShare(share: ShareContent): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.attachmentNotice = t('Could not attach files');
      return;
    }
    this.picking = true;
    try {
      await this.addAttachments(context, share.files, false);
    } catch (err) {
      this.attachmentNotice = t('Could not attach files');
    } finally {
      this.picking = false;
    }
  }

  private async pickFiles(photos: boolean): Promise<void> {
    if (this.room === 0 || this.picking || this.store.send.pending) {
      return;
    }
    this.picking = true;
    this.attachmentNotice = '';
    const scope = this.scope;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const sources = await pickAttachmentSources(context, photos, this.room);
      if (this.active && scope === currentScope()) {
        await this.addAttachments(context, sources, photos);
      }
    } catch (err) {
      if (this.active && scope === currentScope()) {
        this.attachmentNotice = t('Could not attach files');
      }
    } finally {
      this.picking = false;
    }
  }

  private async addAttachments(context: Context, sources: AttachmentSource[], photos: boolean): Promise<void> {
    const imported = await importAttachmentSources(context, sources, photos, this.attachments.length,
      attachmentMaxBytes(app.me), attachmentMaxCount(app.me));
    if (!this.active || currentScope() !== this.scope) {
      for (const item of imported.attachments) {
        removeTemporaryFile(item.path);
      }
      return;
    }
    if (imported.attachments.length) {
      this.store.resetAttempt();
      this.attachments = [...this.attachments, ...imported.attachments];
    }
    const values: Record<string, string | number> = {};
    values['items'] = imported.skipped.join(', ');
    this.attachmentNotice = imported.skipped.length ? t('Skipped {items}', values) : '';
  }

  private removeAttachment(path: string): void {
    if (!this.store.send.pending && !this.picking) {
      this.store.resetAttempt();
      this.attachments = this.attachments.filter((item: DraftAttachment): boolean => item.path !== path);
      removeTemporaryFile(path);
    }
  }

  private sendDraft(imagesAsFiles: boolean = false): void {
    if (!this.canSend || this.scope !== currentScope()) {
      return;
    }
    const text = this.draft.trim();
    if (text.length > THREAD_MESSAGE_TEXT_MAX_LENGTH) {
      const values: Record<string, string | number> = {};
      values['limit'] = new Intl.NumberFormat(currentLocale()).format(THREAD_MESSAGE_TEXT_MAX_LENGTH);
      this.attachmentNotice = t('Messages can be up to {limit} characters.', values);
      return;
    }
    this.attachmentNotice = '';
    this.atBottom = true;
    this.store.sendDraft(text, this.attachments, this.replyTarget?.id ?? '', imagesAsFiles);
  }

  @Builder
  attachmentMenu() {
    Menu() {
      MenuItem({ content: t('Photo library') }).onClick((): void => { void this.pickFiles(true); })
      MenuItem({ content: t('File') }).onClick((): void => { void this.pickFiles(false); })
    }
  }

  /** The message a reply answers, when the transcript holds it. */
  private parentOf(message: LiveMessage | null): LiveMessage | null {
    const id = message?.replyToMessageId;
    if (id === undefined) {
      return null;
    }
    return this.store.snapshot?.messages.find((candidate: LiveMessage): boolean => candidate.id === id) ?? null;
  }

  @Builder
  daySeparator(label: string) {
    Text(label)
      .fontSize(typeScale.caption.fontSize)
      .fontColor(appearance.tokens().faintForeground)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 12, bottom: 6 })
  }

  @Builder
  rowEntry(row: ThreadRow) {
    if (row.type === 'day') {
      // The label resolves here (build-time t()), never baked into the row: a hot locale switch
      // re-renders separators in the new language.
      this.daySeparator(daySeparatorLabel(row.dayAt, Date.now()))
    } else {
      MessageBubble({
        message: row.message,
        parent: this.parentOf(row.message),
        busy: this.store.answer.pending,
        members: this.store.snapshot?.members ?? [],
        meId: app.me?.userId ?? '',
        fallbackAuthor: this.title,
        botId: this.botId,
        groupId: this.groupId,
        canReply: !this.store.send.pending,
        onReply: (message: LiveMessage): void => {
          if (!this.store.send.pending && this.scope === currentScope()) {
            this.store.resetAttempt();
            this.replyTarget = message;
          }
        },
        onJumpTo: (messageId: string): void => {
          // Scrolls to a parent the transcript holds; one outside the loaded window (mobile loads
          // it) and the highlight mobile puts on it arrive with a later milestone.
          const index = this.store.rows.findIndex((candidate: ThreadRow): boolean =>
            candidate.message !== null && candidate.message.id === messageId);
          if (index < 0) {
            return;
          }
          // The list counts its "load earlier messages" row above the transcript.
          this.atBottom = false;
          this.scroller.scrollToIndex(index + (this.store.olderCursor !== null ? 1 : 0), true, ScrollAlign.CENTER);
        },
        onAnswer: (message: LiveMessage, answer: string): void => {
          if (message.runId === undefined) {
            return;
          }
          const input: Record<string, Object> = {};
          input['runId'] = message.runId;
          input['messageId'] = message.id;
          input['answer'] = answer;
          this.store.answer.run(input);
        },
      })
    }
  }

  build() {
    NavDestination() {
      Column() {
      Row({ space: 12 }) {
        Text('‹')
          .fontSize(28)
          .fontColor(appearance.tokens().foreground)
          .padding({ left: 8, right: 8 })
          .accessibilityText(t('Back'))
          .onClick((): void => {
            this.stack.pop();
          })
        Text(this.title)
          .fontSize(typeScale.title.fontSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(appearance.tokens().foreground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.store.working()) {
          Text(t('Stop'))
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().destructive)
            .padding(8)
            .onClick((): void => {
              const input: Record<string, Object> = {};
              this.store.stop.run(input);
            })
        } else if (this.store.connected) {
          Circle()
            .width(8)
            .height(8)
            .fill(appearance.tokens().workingDot)
        }
      }
      .width('100%')
      .padding({ left: 8, right: 16, top: 12, bottom: 8 })

      if (this.store.offline || this.store.error) {
        Row({ space: 8 }) {
          Text(this.store.offline ? t('Could not reach the server') : this.store.error)
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().warning)
            .layoutWeight(1)
          Text(t('Retry'))
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().link)
            .onClick((): void => {
              this.store.retry();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(appearance.tokens().card)
      }

      if (this.store.runError()) {
        ErrorText({ message: this.store.runError() })
          .padding({ left: 16, right: 16, top: 4 })
      }

      if (this.store.loading && this.store.rows.length === 0) {
        Row() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(appearance.tokens().foreground)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.scroller }) {
          if (this.store.olderCursor !== null) {
            ListItem() {
              Row() {
                if (this.store.loadingOlder) {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .color(appearance.tokens().mutedForeground)
                } else {
                  Text(t('Load earlier messages'))
                    .fontSize(typeScale.secondary.fontSize)
                    .fontColor(appearance.tokens().link)
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding(10)
              .onClick((): void => {
                void this.store.loadOlder();
              })
            }
          }
          LazyForEach(this.source, (row: ThreadRow): void => {
            ListItem() {
              this.rowEntry(row)
            }
          }, (row: ThreadRow): string => row.key)
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onScrollIndex((start: number, end: number): void => {
          this.atBottom = end >= this.store.rows.length - 2;
        })
        .onReachStart((): void => {
          void this.store.loadOlder();
        })

        if (this.store.awayFromLatest) {
          ListItem() {
            Row() {
              Text(t('Jump to latest'))
                .fontSize(typeScale.secondary.fontSize)
                .fontColor(appearance.tokens().link)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(10)
            .onClick((): void => {
              this.atBottom = true;
              this.store.jumpToLatest();
            })
          }
        }
      }

      if (this.store.send.error) {
        Row({ space: 8 }) {
          ErrorText({ message: this.store.send.error }).layoutWeight(1)
          Button(this.store.imageConfirmation ? t('Send as file') : t('Retry'))
            .fontSize(typeScale.secondary.fontSize)
            .backgroundColor(appearance.tokens().card)
            .fontColor(appearance.tokens().foreground)
            .onClick((): void => { this.sendDraft(this.store.imageConfirmation); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4 })
      }
      if (this.store.answer.error) {
        ErrorText({ message: this.store.answer.error })
          .padding({ left: 16, right: 16, top: 4 })
      }

      if (this.replyTarget !== null) {
        ComposerReplyPreview({
          message: this.replyTarget, members: this.store.snapshot?.members ?? [], meId: app.me?.userId ?? '',
          title: this.title, botId: this.botId, groupId: this.groupId, busy: this.store.send.pending,
          onClose: (): void => {
            this.store.resetAttempt();
            this.replyTarget = null;
          },
        }).padding({ left: 16, right: 16, top: 4 })
      }
      if (this.attachments.length) {
        ComposerAttachments({ attachments: this.attachments, busy: this.store.send.pending || this.picking,
          onRemove: (path: string): void => { this.removeAttachment(path); } })
          .padding({ left: 16, right: 16, top: 4 })
      }
      if (this.attachmentNotice) {
        ErrorText({ message: this.attachmentNotice }).padding({ left: 16, right: 16, top: 4 })
      }
      if (this.store.uploading > 0) {
        Progress({ value: this.store.uploading, total: this.attachments.length, type: ProgressType.Linear })
          .color(appearance.tokens().primary)
          .accessibilityText(t('Sending…'))
          .padding({ left: 16, right: 16, top: 4 })
      }
      Row({ space: 8 }) {
        Button({ type: ButtonType.Circle }) {
          if (this.picking) {
            LoadingProgress().width(20).height(20).color(appearance.tokens().mutedForeground)
          } else {
            Text('+').fontSize(24).fontColor(appearance.tokens().foreground)
          }
        }
        .id('thread-attach')
        .width(COMPOSER_CONTROL_SIZE)
        .height(COMPOSER_CONTROL_SIZE)
        .backgroundColor(appearance.tokens().card)
        .accessibilityText(t('Attach file'))
        .enabled(this.room > 0 && !this.picking && !this.store.send.pending)
        .bindMenu(this.attachmentMenu)
        TextInput({ text: $$this.draft, placeholder: t('Message…') })
          .layoutWeight(1)
          .height(COMPOSER_CONTROL_SIZE)
          .fontSize(typeScale.body.fontSize)
          .fontColor(appearance.tokens().foreground)
          .placeholderColor(appearance.tokens().faintForeground)
          .backgroundColor(appearance.tokens().card)
          .borderRadius(23)
          .enabled(!this.store.send.pending)
          .onChange((value: string): void => {
            if (value !== this.draft) {
              this.store.resetAttempt();
              this.draft = value;
            }
          })
          .onSubmit((): void => { this.sendDraft(); })
        Button({ type: ButtonType.Circle }) {
          if (this.store.uploading > 0) {
            Text('×').fontSize(24).fontColor(appearance.tokens().primaryForeground)
          } else if (this.store.send.pending) {
            LoadingProgress().width(22).height(22).color(appearance.tokens().primaryForeground)
          } else {
            SymbolGlyph($r('sys.symbol.arrow_up')).fontSize('20vp').fontColor([appearance.tokens().primaryForeground])
          }
        }
        .id('thread-send')
        .width(COMPOSER_CONTROL_SIZE)
        .height(COMPOSER_CONTROL_SIZE)
        .accessibilityText(t(this.store.uploading > 0 ? 'Cancel' : 'Send'))
        .backgroundColor(appearance.tokens().primary)
        .enabled(this.canSend || this.store.uploading > 0)
        .opacity(this.canSend || this.store.send.pending ? 1 : 0.5)
        .onClick((): void => {
          if (this.store.uploading > 0) {
            this.store.cancelUpload();
          } else {
            this.sendDraft();
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(appearance.tokens().background)
    }
    .hideTitleBar(true)
  }
}
