// ThreadPage (design §6.5/§7.2 M3): the open chat. List + LazyForEach over the store's rows
// (day separators, message bubbles, the live progress bubble), history paging on top-reach,
// the composer with send/retry, stop while a run works, ask answers through the same consent
// gate, and markRead on open/foreground/new-message. The screen expresses intent; the store and
// stream own orchestration. Copy reuses catalog msgids; the one placeholder string is centralized.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ListSource } from '../../uikit/list-source';
import { ErrorText } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { app } from '../../app/app-state';
import { ThreadStore, daySeparatorLabel } from '../../stores/thread-store';
import type { ThreadRow } from '../../stores/thread-store';
import { RosterHolder } from '../../realtime/roster-holder';
import { MessageBubble } from './MessageBubble';
import { installConsentDialog } from './consent-dialog';
import type { LiveMessage } from '../../thread/thread-snapshot';

const COMPOSER_CONTROL_SIZE = 46;

@ComponentV2
export struct ThreadPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Param botId: string = '';
  @Param groupId: string = '';
  @Param title: string = '';
  @Local store: ThreadStore = new ThreadStore();
  @Local source: ListSource<ThreadRow> = new ListSource<ThreadRow>([]);
  @Local draft: string = '';
  private holder: RosterHolder = new RosterHolder();

  /** A failed send restores its text to the composer for retry (the store owns the failure). */
  @Monitor('store.sendFailedText')
  onSendFailed(): void {
    if (this.store.sendFailedText && !this.draft) {
      this.draft = this.store.sendFailedText;
    }
  }
  private offChanges: (() => void) | null = null;
  private offConsent: (() => void) | null = null;
  private scroller: Scroller = new Scroller();
  private atBottom: boolean = true;

  aboutToAppear(): void {
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
  }

  aboutToDisappear(): void {
    this.store.setVisible(false);
    this.store.close();
    this.offChanges?.();
    this.offChanges = null;
    this.offConsent?.();
    this.offConsent = null;
    this.holder.stop();
  }

  private sendDraft(): void {
    const text = this.draft.trim();
    if (!text || this.store.send.pending) {
      return;
    }
    const input: Record<string, Object> = {};
    input['text'] = text;
    this.store.send.run(input);
    // No optimistic bubble (design §6.5): the composer clears now; a failed send restores the
    // text through the store's sendFailedText (the @Monitor above).
    this.draft = '';
    this.atBottom = true;
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
        readOnly: false,
        members: this.store.snapshot?.members ?? [],
        meId: app.me?.userId ?? '',
        fallbackAuthor: this.title,
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
          ErrorText({ message: this.store.send.error })
            .layoutWeight(1)
          Text(t('Retry'))
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().link)
            .onClick((): void => {
              this.store.send.reset();
              this.sendDraft();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4 })
      }
      if (this.store.answer.error) {
        ErrorText({ message: this.store.answer.error })
          .padding({ left: 16, right: 16, top: 4 })
      }

      Row({ space: 8 }) {
        // $$ two-way: a programmatic draft restore (failed send / Not now) must reach the field.
        TextInput({ text: $$this.draft, placeholder: t('Message…') })
          .layoutWeight(1)
          .height(COMPOSER_CONTROL_SIZE)
          .fontSize(typeScale.body.fontSize)
          .fontColor(appearance.tokens().foreground)
          .placeholderColor(appearance.tokens().faintForeground)
          .backgroundColor(appearance.tokens().card)
          .borderRadius(23)
          .onChange((value: string): void => {
            this.draft = value;
          })
          .onSubmit((): void => {
            this.sendDraft();
          })
        Button({ type: ButtonType.Circle }) {
          if (this.store.send.pending) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(appearance.tokens().primaryForeground)
          } else {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize('20vp')
              .fontColor([appearance.tokens().primaryForeground])
          }
        }
        .id('thread-send')
        .width(COMPOSER_CONTROL_SIZE)
        .height(COMPOSER_CONTROL_SIZE)
        .accessibilityText(t('Send'))
        .backgroundColor(appearance.tokens().primary)
        .enabled(this.draft.trim().length > 0 && !this.store.send.pending)
        .opacity(this.draft.trim().length > 0 ? 1 : 0.5)
        .onClick((): void => {
          this.sendDraft();
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
