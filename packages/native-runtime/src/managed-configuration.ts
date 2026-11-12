import { z } from "zod";

export const executionOwnerSchema = z
  .object({
    spaceId: z.string().min(1).max(256),
    userId: z.string().min(1).max(256),
    computerId: z.string().min(1).max(256),
  })
  .strict();
