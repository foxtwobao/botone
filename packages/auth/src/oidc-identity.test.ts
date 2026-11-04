import { expect, it } from "vitest";
import { readOidcAccountIdentity } from "./external-account-identity.js";
import { oidcAccountSubject } from "./oidc.js";
import { sealIdToken } from "./token-storage.js";

const issuer = "https://identity.example.test";
const key = "offline-identity-test-key-at-least-32-characters";
function account(subject = "subject-1", claims = { iss: issuer, sub: subject }) {
  return {
    providerId: "oidc",
    accountId: oidcAccountSubject(issuer, subject),
    idToken: `header.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.signature`,
  };
}

it("reads the original subject from a sealed stored binding without changing it", async () => {
  const stored = account(" subject-1 ");
  stored.idToken = (await sealIdToken(key, stored.idToken))!;
  expect(await readOidcAccountIdentity(stored, issuer, key)).toEqual({
    issuer,
    subject: " subject-1 ",
  });
  expect(await readOidcAccountIdentity(stored, issuer, "wrong-key")).toBeNull();
});

it("rejects a different issuer, an unbound subject, missing tokens and other providers", async () => {
  const stored = account();
  for (const invalid of [
    { ...stored, accountId: "unbound" },
    { ...stored, providerId: "credential" },
    { ...stored, idToken: null },
    { ...stored, idToken: "malformed" },
    account("subject-1", { iss: "https://other.example.test", sub: "subject-1" }),
    account(" "),
  ])
    expect(await readOidcAccountIdentity(invalid, issuer, key)).toBeNull();
  expect(await readOidcAccountIdentity(stored, undefined, key)).toBeNull();
});
