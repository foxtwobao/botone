import type { Actor } from "@rakazo/contracts";
import { DisabledBuiltinToolsSchema } from "@rakazo/contracts";
import type { PrismaClient } from "@rakazo/db";
import { createRepos, listApprovalRules, saveApprovalRule } from "@rakazo/db";
import { PERIPHERAL_VOICE_INSTRUCTIONS } from "./voice-bot.prompt.js";

const SPAWN_KEY = "peripheral:podone";

/**
 * Local Pod hardware and voice controls that are safe to execute without a manual
 * approval card. Destructive tools (e.g. self_system_reconfigure_wifi) are omitted
 * so they still require explicit user confirmation.
 */
export const SAFE_POD_TOOLS = [
  "self_audio_speaker_set_volume",
  "self_screen_set_brightness",
  "self_screen_set_theme",
  "self_screen_play_animation",
  "pod_play_music",
  "pod_end_conversation",
] as const;

const seededPodApprovals = new Set<string>();

export async function ensurePodToolApprovals(prisma: PrismaClient, actor: Actor) {
  const key = `${actor.userId}:${actor.spaceId}`;
  if (seededPodApprovals.has(key)) return;
  const existing = await listApprovalRules(prisma, actor);
  const configured = new Set(
    existing
      .filter((rule) => rule.matchKind === "tool")
      .map((rule) => rule.matchValue.toLowerCase()),
  );
  const missing = SAFE_POD_TOOLS.filter((tool) => !configured.has(tool));
  if (missing.length > 0) {
    await prisma.$transaction(async (tx) => {
      for (const tool of missing) {
        await saveApprovalRule(tx, actor, {
          effect: "always_allow",
          matchKind: "tool",
          matchValue: tool,
        });
      }
    });
  }
  if (seededPodApprovals.size >= 1024) seededPodApprovals.clear();
  seededPodApprovals.add(key);
}
const disabledBuiltinTools = DisabledBuiltinToolsSchema.parse([
  "shell",
  "computer_observe",
  "computer_act",
  "browser_navigate",
  "browser_snapshot",
  "browser_act",
  "user_computer_list",
  "user_computer_shell",
  "user_computer_observe",
  "user_computer_act",
  "open_path",
  "launch_app",
  "request_takeover",
  "list_files",
  "read_file",
  "write_file",
  "attach_file",
  "save_page",
]);

export async function existingVoiceBot(prisma: PrismaClient, actor: Actor) {
  const bot = await prisma.bot.findUnique({
    where: { spaceId_spawnKey: { spaceId: actor.spaceId, spawnKey: SPAWN_KEY } },
    select: { id: true, archivedAt: true },
  });
  return bot && !bot.archivedAt ? bot : null;
}

export async function ensureVoiceBot(prisma: PrismaClient, actor: Actor) {
  await ensurePodToolApprovals(prisma, actor);
  const existing = await existingVoiceBot(prisma, actor);
  if (existing) return existing.id;

  const bot = await createRepos(prisma).createBot(actor, {
    name: "波波",
    description: "",
    instructions: PERIPHERAL_VOICE_INSTRUCTIONS,
    spawnKey: SPAWN_KEY,
    notifyOnFinish: false,
    fleetManagement: true,
    thinkingLevel: "off",
    disabledBuiltinTools,
  });
  return bot.id;
}
