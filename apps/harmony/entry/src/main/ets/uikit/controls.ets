// Shared controls: one button rhythm and one field rhythm across the M1 screens, colored by
// the generated mobile palette. Native ArkUI controls only (design native-first rule).
import { appearance } from './theme';
import { typeScale } from './tokens.generated';

@ComponentV2
export struct ActionButton {
  @Param label: string = '';
  /** primary | secondary | destructive */
  @Param kind: string = 'primary';
  @Param busy: boolean = false;
  @Param disabled: boolean = false;
  @Event onTap: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      if (this.busy) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.kind === 'primary' ? appearance.tokens().primaryForeground : appearance.tokens().foreground)
      } else {
        Text(this.label)
          .fontSize(typeScale.body.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.kind === 'primary' ? appearance.tokens().primaryForeground
            : this.kind === 'destructive' ? appearance.tokens().destructive : appearance.tokens().foreground)
      }
    }
    .width('100%')
    .height(46)
    .backgroundColor(this.kind === 'primary' ? appearance.tokens().primary
      : this.kind === 'destructive' ? appearance.tokens().background : appearance.tokens().muted)
    .borderWidth(this.kind === 'destructive' ? 1 : 0)
    .borderColor(appearance.tokens().destructive)
    .enabled(!this.disabled && !this.busy)
    .opacity(this.disabled && !this.busy ? 0.5 : 1)
    .onClick((): void => {
      this.onTap();
    })
  }
}

@ComponentV2
export struct Field {
  @Param label: string = '';
  @Param placeholder: string = '';
  @Param value: string = '';
  @Param secure: boolean = false;
  @Param email: boolean = false;
  @Param disabled: boolean = false;
  @Event onChange: (value: string) => void = (): void => {};

  build() {
    Column({ space: 6 }) {
      Text(this.label)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
        .alignSelf(ItemAlign.Start)
      TextInput({ text: this.value, placeholder: this.placeholder })
        .type(this.secure ? InputType.Password : this.email ? InputType.Email : InputType.Normal)
        .height(46)
        .fontSize(typeScale.body.fontSize)
        .fontColor(appearance.tokens().foreground)
        .placeholderColor(appearance.tokens().faintForeground)
        .placeholderFont({ size: typeScale.body.fontSize })
        .caretColor(appearance.tokens().primary)
        .backgroundColor(appearance.tokens().card)
        .borderRadius(12)
        .enabled(!this.disabled)
        .onChange((value: string): void => {
          this.onChange(value);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** Inline error copy in the destructive token; the one place failures surface on a screen. */
@ComponentV2
export struct ErrorText {
  @Param message: string = '';

  build() {
    if (this.message) {
      Text(this.message)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().destructive)
        .width('100%')
        .textAlign(TextAlign.Start)
    }
  }
}
