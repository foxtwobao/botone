import type { DesktopHostBridge } from "@rakazo/contracts";
import { desktopBridge } from "./desktop";

/** Resolve the device's choice on each send; a failed local send never falls through to a server run. */
export async function selectedHostHarness(input: {
  botId?: string;
  groupId?: string;
  spaceId?: string;
}): Promise<DesktopHostBridge | null> {
  const bridge = desktopBridge()?.harness;
  if (!bridge || !input.botId || input.groupId) return null;
  if (!input.spaceId) throw new Error("Local agent unavailable");
  return (await bridge.selection({ botId: input.botId, spaceId: input.spaceId })) ? bridge : null;
}
