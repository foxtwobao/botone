/** CSS #RRGGBBAA → ArkUI #AARRGGBB; every other form passes through unchanged. */
export function toArkColor(value: string): string {
  if (/^#[0-9a-fA-F]{8}$/.test(value)) {
    return `#${value.slice(7)}${value.slice(1, 7)}`;
  }
  return value;
}
