// Chat avatars (design §6.1): a bot carries its identity color (the server's bots.color, parsed
// like contracts' parseBotAvatarValue); a group is neutral (bots carry the only color). The
// fallback is the generated botColors palette, exactly mobile's FALLBACK_COLOR = botColors[3].
// A working run shows the one green dot (tokens.workingDot); unread shows the one blue dot.
import { appearance } from './theme';
import { botColors } from './tokens.generated';

const HEX_COLOR = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

/** The hex a bot's avatar value names; image/shapeless/other values fall back to the palette. */
export function resolveBotColor(raw: string): string {
  const fallback = botColors[3];
  if (!raw || raw.startsWith('data:image/')) {
    return fallback;
  }
  if (raw.includes('::shape_')) {
    const color = raw.split('::shape_')[0];
    return HEX_COLOR.test(color) ? color : fallback;
  }
  return HEX_COLOR.test(raw) ? raw : fallback;
}

function initial(name: string): string {
  const trimmed = name.trim();
  return trimmed ? trimmed.charAt(0).toUpperCase() : '?';
}

/** A light identity color (e.g. #FFFFFF) needs a dark initial; a dark one needs white. */
function initialColor(hex: string): string {
  const value = hex.replace('#', '');
  const full = value.length === 3
    ? value.charAt(0) + value.charAt(0) + value.charAt(1) + value.charAt(1) + value.charAt(2) + value.charAt(2)
    : value;
  const r = parseInt(full.substring(0, 2), 16);
  const g = parseInt(full.substring(2, 4), 16);
  const b = parseInt(full.substring(4, 6), 16);
  const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return luminance > 0.6 ? '#1A1A1A' : '#FFFFFF';
}

@ComponentV2
export struct ChatAvatar {
  @Param kind: string = 'bot';
  @Param name: string = '';
  @Param color: string = '';
  @Param working: boolean = false;
  @Param diameter: number = 48;

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Circle()
        .width(this.diameter)
        .height(this.diameter)
        .fill(this.kind === 'bot' ? resolveBotColor(this.color) : appearance.tokens().muted)
      Text(initial(this.name))
        .fontSize(this.diameter * 0.42)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.kind === 'bot' ? initialColor(resolveBotColor(this.color)) : appearance.tokens().mutedForeground)
        .width(this.diameter)
        .height(this.diameter)
        .textAlign(TextAlign.Center)
      if (this.working) {
        Circle()
          .width(this.diameter * 0.28)
          .height(this.diameter * 0.28)
          .fill(appearance.tokens().workingDot)
          .stroke(appearance.tokens().background)
          .strokeWidth(2)
      }
    }
    .width(this.diameter)
    .height(this.diameter)
  }
}

/** The one blue unread dot (tokens.unread). */
@ComponentV2
export struct UnreadDot {
  @Param diameter: number = 8;

  build() {
    Circle()
      .width(this.diameter)
      .height(this.diameter)
      .fill(appearance.tokens().unread)
  }
}

/** Row time: today as HH:mm, otherwise a numeric date (localized dates arrive with M4). */
export function formatRowTime(iso: string, now: number): string {
  const date = new Date(iso);
  const time = date.getTime();
  if (Number.isNaN(time)) {
    return '';
  }
  const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
  const startOfDay = (d: Date): number => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const dayDiff = Math.round((startOfDay(new Date(now)) - startOfDay(date)) / 86_400_000);
  if (dayDiff <= 0) {
    return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }
  const month = date.getMonth() + 1;
  const day = date.getDate();
  if (date.getFullYear() !== new Date(now).getFullYear()) {
    return `${date.getFullYear()}/${month}/${day}`;
  }
  return `${month}/${day}`;
}

/** A one-line preview snippet; an empty preview reads as the shared "No messages yet" msgid. */
export function previewSnippet(preview: string, max: number): string {
  const flat = preview.replace(/\s+/g, ' ').trim();
  return flat.length > max ? flat.slice(0, max) : flat;
}
