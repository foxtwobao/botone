// Adapted from OpenMausBot server/drivers/acp/deepseek.ts. See NOTICE.md.

import { acpDriver } from "./acp.js";
import { deepseekWireValue } from "./acp-config.js";

export const createDeepseekDriver = acpDriver({
  resumeMethod: "session/resume",
  modelValue: deepseekWireValue,
});
