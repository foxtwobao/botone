import { constants } from "node:fs";
import { open, realpath } from "node:fs/promises";
import path from "node:path";

/** The opened descriptor, rather than an earlier path check, is the authority under rename races. */
export async function readNativeWorkspaceFile(workspace: string, file: string, home?: string) {
  const root = await realpath(workspace);
  if (home && !root.startsWith(`${await realpath(home)}${path.sep}`))
    throw new Error("file_outside_workspace");
  const relative = file.startsWith("/workspace/") ? file.slice("/workspace/".length) : file;
  if (path.isAbsolute(relative) || relative.split(path.sep).includes(".."))
    throw new Error("invalid_file_path");
  const handle = await open(
    path.join(root, relative),
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const actual = await realpath(`/proc/self/fd/${handle.fd}`);
    if (!actual.startsWith(`${root}${path.sep}`)) throw new Error("file_outside_workspace");
    const info = await handle.stat();
    if (!info.isFile() || info.size > 1024 * 1024) throw new Error("invalid_workspace_file");
    const buffer = Buffer.alloc(1024 * 1024 + 1);
    let size = 0;
    while (size < buffer.length) {
      const read = await handle.read(buffer, size, buffer.length - size, null);
      if (!read.bytesRead) break;
      size += read.bytesRead;
    }
    if (size > 1024 * 1024) throw new Error("workspace_file_limit");
    return { name: path.basename(relative), content: buffer.subarray(0, size).toString("base64") };
  } finally {
    await handle.close();
  }
}
