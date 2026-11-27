// Provider buttons for the sign-in chooser and the SSO-only screen, the shape of mobile's
// social-sign-in-buttons on harmony primitives: primary providers as full-width buttons with
// the server's presentation mark (Shape + Path, no bundled vendor assets), "Continue with
// email" and the passkey entry as outline buttons, organization SSO as a quiet text link.
// The variant decides the surface: outline renders outlined on the page color, anything else
// solid on the primary ink.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { t } from '../../i18n/i18n';
import type { ProviderMarkPathView, ProviderMarkView } from '../../contract/decode';

const MARK_SIZE = 20;

@ComponentV2
export struct ProviderMark {
  @Param mark: ProviderMarkView = { viewBox: '0 0 24 24', paths: [] } as ProviderMarkView;
  /** The color a path carries when the server sent none for it. */
  @Param color: string = '#111111';

  /** "0 0 24 24" → [x, y, width, height]; a broken viewBox draws nothing. */
  private bounds(): number[] {
    const parts = this.mark.viewBox.split(/[\s,]+/);
    const values: number[] = [];
    for (const part of parts) {
      const value = Number(part);
      if (!Number.isNaN(value)) {
        values.push(value);
      }
    }
    if (values.length !== 4 || values[2] <= 0 || values[3] <= 0) {
      return [0, 0, 24, 24];
    }
    return values;
  }

  build() {
    Shape() {
      ForEach(this.mark.paths, (path: ProviderMarkPathView): void => {
        Path()
          .commands(path.d)
          .fill(path.fill !== null && path.fill !== '' ? path.fill : this.color)
          .width('100%')
          .height('100%')
      }, (path: ProviderMarkPathView): string => path.d)
    }
    .viewPort({ x: this.bounds()[0], y: this.bounds()[1], width: this.bounds()[2], height: this.bounds()[3] })
    .width(MARK_SIZE)
    .height(MARK_SIZE)
  }
}

@ComponentV2
export struct ProviderButton {
  @Param label: string = '';
  /** The server's mark, absent for the email and passkey rows. */
  @Param mark: ProviderMarkView | null = null;
  /** True for the email and passkey rows: the fixed envelope mark, not the server's. */
  @Param stroked: boolean = false;
  /** Outline surface (page color, border) instead of solid primary ink. */
  @Param outlined: boolean = false;
  @Param disabled: boolean = false;
  @Event onTap: () => void = (): void => {};

  build() {
    Row({ space: 10 }) {
      if (this.mark !== null && !this.stroked) {
        ProviderMark({
          mark: this.mark,
          color: this.outlined ? appearance.tokens().foreground : appearance.tokens().primaryForeground,
        })
      }
      if (this.stroked) {
        MailMark({ color: appearance.tokens().foreground })
      }
      Text(this.label)
        .fontSize(typeScale.body.fontSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.outlined ? appearance.tokens().foreground : appearance.tokens().primaryForeground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(46)
    .justifyContent(FlexAlign.Center)
    .borderRadius(23)
    .backgroundColor(this.outlined ? appearance.tokens().background : appearance.tokens().primary)
    .borderWidth(this.outlined ? 1 : 0)
    .borderColor(appearance.tokens().border)
    .enabled(!this.disabled)
    .opacity(this.disabled ? 0.5 : 1)
    .onClick((): void => {
      this.onTap();
    })
  }
}

/** The quiet "Continue with {name}" text link for organization SSO beside personal providers. */
@ComponentV2
export struct ProviderTextLink {
  @Param label: string = '';
  @Param disabled: boolean = false;
  @Event onTap: () => void = (): void => {};

  build() {
    Text(this.label)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(appearance.tokens().mutedForeground)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ top: 10, bottom: 10, left: 16, right: 16 })
      .opacity(this.disabled ? 0.45 : 1)
      .onClick((): void => {
        this.onTap();
      })
  }
}

/** The envelope mark on "Continue with email": two stroked paths, mobile's MailMark. */
@ComponentV2
export struct MailMark {
  @Param color: string = '#111111';

  build() {
    Shape() {
      Path()
        .commands('M4 7.2C4 6 5 5 6.2 5h11.6C19 5 20 6 20 7.2v9.6c0 1.2-1 2.2-2.2 2.2H6.2C5 19 4 18 4 16.8V7.2Z')
        .stroke(this.color)
        .strokeWidth(1.8)
        .fillOpacity(0)
        .width('100%')
        .height('100%')
      Path()
        .commands('M4.6 7.4 12 13l7.4-5.6')
        .stroke(this.color)
        .strokeWidth(1.8)
        .strokeLineCap(LineCapStyle.Round)
        .fillOpacity(0)
        .width('100%')
        .height('100%')
    }
    .viewPort({ x: 0, y: 0, width: 24, height: 24 })
    .width(MARK_SIZE)
    .height(MARK_SIZE)
  }
}

/** "Continue with {name}" copy for a provider row. */
export function providerLabel(name: string): string {
  const values: Record<string, string> = {};
  values['name'] = name;
  return t('Continue with {name}', values);
}
