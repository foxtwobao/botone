// Differential check for the sign-in email-typo port (PR1): the ArkTS port's suggestion
// against the real suggestEmailCorrection in core, over a corpus of clean addresses, known
// domains, and the typo shapes the reference was built for. The port is the .ets source
// loaded as erasable TS, the same trick the message-text port test uses; any disagreement
// fails with the case printed. Not a fixture: it reads the reference directly.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as core from "@rakazo/core";
import { afterAll, describe, expect, it } from "vitest";

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, "../entry");
const outDir = mkdtempSync(path.join(tmpdir(), "harmony-signin-port-"));
// The port reads only i18n's t() through no import at all: email-typo.ets is standalone, so
// the copy gets a plain .ts extension and loads without its neighbors. Its COM_TYPOS is an
// array (ArkTS forbids Set literals) whose includes() matches the reference's Set.has.
mkdirSync(path.join(outDir, "signin"), { recursive: true });
writeFileSync(
  path.join(outDir, "signin", "email-typo.ts"),
  readFileSync(path.join(appRoot, "src/main/ets/features/signin/email-typo.ets"), "utf8"),
);

afterAll(() => {
  rmSync(outDir, { recursive: true, force: true });
});

describe("harmony email-typo port", () => {
  it("matches the TypeScript reference", async () => {
    const port = (await import(
      pathToFileURL(path.join(outDir, "signin", "email-typo.ts")).href
    )) as { suggestEmailCorrection: (email: string) => string | null };
    const ADDRESSES = [
      "a@gmail.com",
      "ada@example.com",
      "ada@gmial.com",
      "ada@gmai.com",
      "ada@gmail.co",
      "ada@gmail.con",
      "ada@gmail.cmo",
      "ada@gmal.com",
      "ada@googlemail.com",
      "ada@gnail.com",
      "ada@icloud.com",
      "ada@iclod.com",
      "ada@outlook.com",
      "ada@otlook.com",
      "ada@hotmail.com",
      "ada@hotmail.co",
      "ada@yahoo.com",
      "ada@yaho.com",
      "ada@proton.me",
      "ada@proton.me.con",
      "ada@qq.com",
      "ada@163.com",
      "ada@126.con",
      "ada@foxmail.com",
      "ada@foxmai.com",
      "ada@gmx.com",
      "ada@gmx.con",
      "ada@mail.com",
      "ada@email.con",
      "ada@me.com",
      "ada@me.con",
      "ada@live.com",
      "ada@msn.com",
      "ada@aol.com",
      "ada@ymail.com",
      "ada@protonmail.com",
      // Short names are never fuzzy (gm.com, ge.com sit one edit from real ones).
      "ada@gm.com",
      "ada@ge.com",
      "ada@me.cmo",
      // First letters rarely move; a lookalike real domain keeps its suggestion only when
      // the reference agrees.
      "ada@cloud.com",
      "ada@vaild.com",
      // No @, leading @, subdomains, plus-addressing, unicode, whitespace.
      "ada",
      "@example.com",
      "ada@",
      "a@b.c",
      "ada+tag@gmail.con",
      "ada@sub.gmail.con",
      "ada@GMAIL.CON",
      " ada@gmail.con ",
      "ada@例え.con",
      // Long domains beyond the reference's length guard.
      `ada@${"a".repeat(250)}.con`,
    ];
    const failures: { input: string; expected: string | null; actual: string | null }[] = [];
    for (const email of ADDRESSES) {
      const expected = core.suggestEmailCorrection(email);
      const actual = port.suggestEmailCorrection(email);
      if (expected !== actual) {
        failures.push({ input: email, expected, actual });
      }
    }
    expect(failures).toEqual([]);
  });
});
