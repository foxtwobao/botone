import { expect, test } from "@playwright/test";
import type { Bot, Routine } from "@rakazo/contracts";
import { captureScreenshot, completeOnboarding, rpc, signup } from "./helpers";

const ADMIN_EMAIL = "admin@rakazo.test";

const listing = {
  id: "e2e-briefing",
  version: 1,
  name: "E2E briefing",
  summary: "A weekday morning overview.",
  sample: "**Today**\n- 10:00 design review",
  description: "A scannable briefing every weekday morning.",
  instructions: "Summarise the day; never send without confirmation.",
  skills: [],
  routines: [{ name: "Morning briefing", prompt: "Summarise my day", crons: ["0 8 * * 1-5"] }],
  apps: [],
  author: { name: "Rakazo Team" },
  license: "Apache-2.0",
  category: "personal",
  tagline: "Your weekday morning overview.",
  outcomes: ["A scannable morning briefing."],
  intro: "I brief you every weekday morning. Nothing is sent without your confirmation.",
  firstQuestion: "Which city should I watch the weather for?",
};

/** Open signups get a session at once; the emailed link marks the address verified. */
async function verifyEmail(page: import("@playwright/test").Page, email: string) {
  const emailApi = process.env.API_URL ?? "http://127.0.0.1:3110";
  const sentToUser = async () => {
    const response = await page.request.get(`${emailApi}/__e2e/emails`);
    const messages = (await response.json()) as Array<{
      to: string;
      subject: string;
      text: string;
    }>;
    // The brand in the subject follows the deployment's product name.
    return messages.filter(
      (message) => message.to === email && message.subject.startsWith("Verify your"),
    );
  };
  await expect.poll(async () => (await sentToUser()).length).toBeGreaterThan(0);
  const url = (await sentToUser()).at(-1)!.text.match(/https?:\/\/\S+/)?.[0];
  expect(url).toBeTruthy();
  await page.goto(url!);
}

test("ops maintains the catalog online and installs create an inert bot", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const stamp = Date.now();
  await signup(page, ADMIN_EMAIL, "password12", "Market Admin");
  await verifyEmail(page, ADMIN_EMAIL);
  await page.goto("/onboarding");
  await completeOnboarding(page);

  await page.goto("/admin/bots");
  const panel = page.getByTestId("admin-bots");
  await expect(panel.getByText("No bots here yet.", { exact: true })).toBeVisible();
  await captureScreenshot(page, testInfo, "bot-marketplace-admin-empty");

  // Create a draft through the editor, with the preview users will see.
  await panel.getByRole("button", { name: "New bot", exact: true }).click();
  const editor = page.getByRole("dialog");
  await editor.getByTestId("bot-listing-json").fill(JSON.stringify(listing, null, 2));
  await editor.getByRole("button", { name: "Preview", exact: true }).click();
  const preview = editor.getByTestId("bot-marketplace-detail");
  await expect(preview.getByRole("heading", { name: "E2E briefing" })).toBeVisible();
  await expect(preview.getByText("Demo data, not your real content.")).toBeVisible();
  await captureScreenshot(page, testInfo, "bot-marketplace-admin-editor");
  await editor.getByRole("button", { name: "Save", exact: true }).click();
  await expect(editor).toHaveCount(0);
  const row = panel.getByRole("listitem").filter({ hasText: "E2E briefing" });
  await expect(row.getByText("Draft", { exact: true })).toBeVisible();

  // A draft is invisible to users.
  expect((await rpc<{ entries: unknown[] }>(page, "botMarketplace/catalog", {})).entries).toEqual(
    [],
  );

  // Publishing is immediate.
  await row.getByRole("button", { name: "Publish", exact: true }).click();
  await expect(row.getByText("Published", { exact: true })).toBeVisible();
  await captureScreenshot(page, testInfo, "bot-marketplace-admin-published");
  const catalog = await rpc<{ entries: { slug: string; botId: string | null }[] }>(
    page,
    "botMarketplace/catalog",
    {},
  );
  expect(catalog.entries).toEqual([expect.objectContaining({ slug: "e2e-briefing", botId: null })]);

  // An install from an older view is refused; the current one creates an inert bot.
  await expect(
    rpc(page, "botMarketplace/install", { slug: "e2e-briefing", version: 99 }),
  ).rejects.toThrow(/412/);
  const installed = await rpc<{ bot: Bot; created: boolean }>(page, "botMarketplace/install", {
    slug: "e2e-briefing",
    version: 1,
  });
  expect(installed.created).toBe(true);
  const routines = await rpc<Routine[]>(page, "routines/list", { botId: installed.bot.id });
  expect(routines.map((routine) => [routine.name, routine.active])).toEqual([
    ["Morning briefing", false],
  ]);
  await page.goto(`/app/${installed.bot.id}`);
  await expect(page.getByTestId("import-setup-card")).toBeVisible();
  await captureScreenshot(page, testInfo, "bot-marketplace-installed-chat");

  // A retry returns the same bot instead of a second one.
  const again = await rpc<{ bot: Bot; created: boolean }>(page, "botMarketplace/install", {
    slug: "e2e-briefing",
    version: 1,
  });
  expect(again.created).toBe(false);
  expect(again.bot.id).toBe(installed.bot.id);

  // Editing content bumps the version at once; the installed bot keeps its snapshot.
  await page.goto("/admin/bots");
  await row.getByRole("button", { name: "Edit", exact: true }).click();
  await editor
    .getByTestId("bot-listing-json")
    .fill(JSON.stringify({ ...listing, tagline: "A sharper morning overview." }, null, 2));
  await editor.getByRole("button", { name: "Save", exact: true }).click();
  await expect(editor).toHaveCount(0);
  await expect(row.getByText(/v2/)).toBeVisible();
  const got = await rpc<{ listing: { version: number }; botId: string | null }>(
    page,
    "botMarketplace/get",
    { slug: "e2e-briefing" },
  );
  expect(got.listing.version).toBe(2);
  expect(got.botId).toBe(installed.bot.id);

  // Unpublishing hides the listing at once; the installed bot is unaffected.
  await row.getByRole("button", { name: "Unpublish", exact: true }).click();
  await expect(row.getByText("Unpublished", { exact: true })).toBeVisible();
  expect((await rpc<{ entries: unknown[] }>(page, "botMarketplace/catalog", {})).entries).toEqual(
    [],
  );
  await expect(rpc(page, "botMarketplace/get", { slug: "e2e-briefing" })).rejects.toThrow(/404/);
  await page.goto(`/app/${installed.bot.id}`);
  await expect(page.getByTestId("import-setup-card")).toBeVisible();

  // A regular member cannot touch the admin API.
  const memberContext = await page.context().browser()!.newContext();
  try {
    const memberPage = await memberContext.newPage();
    await signup(memberPage, `market-member-${stamp}@rakazo.test`, "password12", "Market Member");
    await expect(rpc(memberPage, "botMarketplace/admin/list", {})).rejects.toThrow(/403/);
  } finally {
    await memberContext.close();
  }
});
