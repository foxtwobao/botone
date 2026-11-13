import { z } from "zod";

const filePath = z.string().min(1).max(4096);
export const hostComputerInputs = {
  computer_execute: z
    .object({ argv: z.array(z.string().max(16384)).min(1).max(128), cwd: filePath.optional() })
    .strict(),
  computer_read_file: z.object({ path: filePath }).strict(),
  computer_write_file: z.object({ path: filePath, text: z.string().max(524288) }).strict(),
  computer_list_files: z.object({ path: filePath }).strict(),
  computer_attach_file: z.object({ path: filePath }).strict(),
};
export const HostComputerCallSchema = z.discriminatedUnion("name", [
  z.object({ name: z.literal("computer_execute"), input: hostComputerInputs.computer_execute }),
  z.object({ name: z.literal("computer_read_file"), input: hostComputerInputs.computer_read_file }),
  z.object({
    name: z.literal("computer_write_file"),
    input: hostComputerInputs.computer_write_file,
  }),
  z.object({
    name: z.literal("computer_list_files"),
    input: hostComputerInputs.computer_list_files,
  }),
  z.object({
    name: z.literal("computer_attach_file"),
    input: hostComputerInputs.computer_attach_file,
  }),
]);
export type HostComputerCall = z.infer<typeof HostComputerCallSchema>;

export const hostComputerTools = Object.entries(hostComputerInputs).map(([name, schema]) => ({
  name,
  label: {
    computer_execute: "Run command",
    computer_read_file: "Read file",
    computer_write_file: "Write file",
    computer_list_files: "List files",
    computer_attach_file: "Attach file",
  }[name]!,
  description: {
    computer_execute:
      "Run an argv command on the selected remote computer. Paths are relative to its workspace; commands have a 30 second limit.",
    computer_read_file: "Read a UTF-8 text file from the selected remote computer's workspace.",
    computer_write_file: "Write a UTF-8 text file in the selected remote computer's workspace.",
    computer_list_files:
      "List files in the selected remote computer's workspace. Use '.' for its root.",
    computer_attach_file:
      "Attach a file from the selected remote computer's workspace to this chat.",
  }[name]!,
  inputSchema: z.toJSONSchema(schema),
  requiresApproval:
    name === "computer_execute" ||
    name === "computer_write_file" ||
    name === "computer_attach_file",
}));
