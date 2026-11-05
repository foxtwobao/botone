import type { Auth } from "@rakazo/auth";
import type { Actor } from "@rakazo/contracts";
import type { PrismaClient } from "@rakazo/db";
import { beforeEach, expect, it, vi } from "vitest";
import { userAppCredentialReader } from "./connected-app-credentials.js";

const { identity } = vi.hoisted(() => ({ identity: vi.fn() }));
vi.mock("@rakazo/auth/identity", () => ({ readExternalAccountIdentity: identity }));
const prisma = {} as PrismaClient;
const actor: Actor = {
  userId: "user-a",
  spaceId: "space-a",
  email: "demo@example.test",
  isDeploymentOwner: false,
};
const binding = {
  accountId: "account-a",
  binding: "binding-a",
  issuer: "https://identity.example.test",
  subject: "subject-a",
};
function authFixture() {
  const getAccessToken = vi.fn(async () => ({
    accessToken: "fake-user-access",
    accessTokenExpiresAt: new Date(Date.now() + 60_000),
  }));
  const refreshToken = vi.fn(async () => ({
    accessToken: "fake-refreshed-access",
    accessTokenExpiresAt: new Date(Date.now() + 60_000),
  }));
  const auth = {
    $context: Promise.resolve({ secretConfig: "fake-encryption-key" }),
    api: { getAccessToken, refreshToken },
  } as unknown as Auth;
  return {
    auth,
    getAccessToken,
    refreshToken,
    read: userAppCredentialReader(prisma, auth, binding.issuer),
  };
}
beforeEach(() => {
  vi.clearAllMocks();
  identity.mockResolvedValue({ ...binding });
});
it("gets and refreshes the exact user's stored account through the existing auth API", async () => {
  const f = authFixture();
  const credential = await f.read(actor.userId);
  expect(credential).toMatchObject({
    accountId: "account-a",
    binding: "binding-a",
  });
  expect(f.getAccessToken).not.toHaveBeenCalled();
  expect(await credential!.accessToken()).toBe("fake-user-access");
  expect(f.getAccessToken).toHaveBeenCalledWith({
    body: { userId: "user-a", accountId: "account-a" },
  });
  expect(await credential!.refreshAccessToken!()).toBe("fake-refreshed-access");
  expect(f.refreshToken).toHaveBeenCalledWith({
    body: { userId: "user-a", accountId: "account-a" },
  });
});
it("does not obtain credentials without a verified binding", async () => {
  const f = authFixture();
  identity.mockResolvedValue(null);
  expect(await f.read(actor.userId)).toBeNull();
  expect(f.getAccessToken).not.toHaveBeenCalled();
});
it("stops if the bound account changes while obtaining or refreshing its token", async () => {
  const f = authFixture();
  identity
    .mockResolvedValueOnce(binding)
    .mockResolvedValueOnce(binding)
    .mockResolvedValueOnce({ ...binding, binding: "replaced" });
  await expect(
    f.read(actor.userId).then((credential) => credential!.accessToken()),
  ).rejects.toMatchObject({ code: "account_changed" });
  identity.mockResolvedValue(binding);
  const credential = await f.read(actor.userId);
  identity.mockResolvedValue({ ...binding, accountId: "account-b" });
  await expect(credential!.refreshAccessToken!()).rejects.toMatchObject({
    code: "account_changed",
  });
  expect(f.refreshToken).not.toHaveBeenCalled();
});
it("separates invalid authentication from temporary failures without exposing provider errors", async () => {
  const f = authFixture();
  f.getAccessToken.mockRejectedValueOnce({ body: { code: "ACCOUNT_NOT_FOUND" } });
  await expect(
    f.read(actor.userId).then((credential) => credential!.accessToken()),
  ).rejects.toMatchObject({
    code: "authentication_required",
    status: 401,
  });
  f.getAccessToken.mockRejectedValueOnce(new Error("fake-sensitive-provider-detail"));
  await expect(
    f.read(actor.userId).then((credential) => credential!.accessToken()),
  ).rejects.toMatchObject({
    code: "authentication_unavailable",
    status: 503,
    message: "Application credential: authentication_unavailable",
  });
  f.getAccessToken.mockResolvedValueOnce({
    accessToken: "expired-access",
    accessTokenExpiresAt: new Date(0),
  });
  await expect(
    f.read(actor.userId).then((credential) => credential!.accessToken()),
  ).rejects.toMatchObject({ code: "authentication_required" });
});
