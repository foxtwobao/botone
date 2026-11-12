import { execFile } from "node:child_process";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { expect, it } from "vitest";
import { workspaceFileProgram } from "./workspace-file.js";

async function readNativeWorkspaceFile(
  workspace: string,
  file: string,
  home = path.dirname(workspace),
) {
  const { stdout } = await promisify(execFile)(
    "python3",
    ["-c", workspaceFileProgram, workspace, home, file],
    { maxBuffer: 2 * 1024 * 1024 },
  );
  return JSON.parse(stdout);
}

it("exports only bounded regular files from the actual workspace descriptor", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "native-file-test-"));
  try {
    const workspace = path.join(root, "workspace");
    await mkdir(workspace);
    await writeFile(path.join(root, "private.txt"), "fake-private");
    await writeFile(path.join(workspace, "result.txt"), "中文🙂");
    expect(await readNativeWorkspaceFile(workspace, path.join(workspace, "result.txt"))).toEqual(
      await readNativeWorkspaceFile(workspace, "result.txt"),
    );
    await symlink(root, path.join(workspace, "escape"));
    await symlink(path.join(root, "private.txt"), path.join(workspace, "link.txt"));
    expect(await readNativeWorkspaceFile(workspace, "/workspace/result.txt")).toEqual({
      name: "result.txt",
      content: Buffer.from("中文🙂").toString("base64"),
    });
    for (const file of ["../private.txt", "/etc/passwd", "escape/private.txt", "link.txt", "."])
      await expect(readNativeWorkspaceFile(workspace, file)).rejects.toThrow();
    await writeFile(path.join(workspace, "large.txt"), Buffer.alloc(1024 * 1024 + 1));
    await expect(readNativeWorkspaceFile(workspace, "large.txt")).rejects.toThrow();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

it("rejects a workspace redirected outside the computer home", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "native-home-test-"));
  try {
    const home = path.join(root, "home");
    await mkdir(home);
    await writeFile(path.join(root, "private.txt"), "fake-private");
    await symlink(root, path.join(home, "workspace"));
    await expect(
      readNativeWorkspaceFile(path.join(home, "workspace"), "private.txt", home),
    ).rejects.toThrow("file_outside_workspace");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
