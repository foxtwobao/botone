// Adapted from OpenMausBot server/drivers/acp/config-options.ts. See NOTICE.md.
import { record, text } from "./driver.js";

export function acpModelOption(result: unknown) {
  const options = record(result).configOptions;
  if (!Array.isArray(options)) return undefined;
  const option = options
    .map(record)
    .find(
      (entry) => entry.type === "select" && (entry.id === "model" || entry.category === "model"),
    );
  if (!option || !text(option.id)) return undefined;
  const values = new Set<string>();
  const collect = (raw: unknown, depth = 0) => {
    if (!Array.isArray(raw) || depth > 8) return;
    for (const item of raw.map(record)) {
      if (text(item.value)) values.add(text(item.value));
      else collect(item.options, depth + 1);
    }
  };
  collect(option.options);
  return { id: text(option.id), current: text(option.currentValue), values };
}

/** The wire uses a JSON pair, while the execution configuration uses provider/model. */
export function deepseekWireValue(model: string) {
  const slash = model.indexOf("/");
  return slash > 0 && slash < model.length - 1
    ? JSON.stringify([model.slice(0, slash), model.slice(slash + 1)])
    : model;
}

/** Hide the ACP connection namespace in discovery labels, retaining the model's own path. */
export function deepseekModelLabel(model: string) {
  const slash = model.indexOf("/");
  return slash > 0 && slash < model.length - 1 ? model.slice(slash + 1) : model;
}
