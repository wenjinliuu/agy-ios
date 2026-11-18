import test from "node:test";
import assert from "node:assert/strict";
import {
  authorizeRole,
  constantTimeTokenEqual,
  extractBearerToken,
} from "../src/auth.ts";

test("constantTimeTokenEqual validates exact match and rejects mismatches", async () => {
  assert.equal(await constantTimeTokenEqual("secret-123", "secret-123"), true);
  assert.equal(await constantTimeTokenEqual("secret-123", "secret-124"), false);
  assert.equal(await constantTimeTokenEqual("secret-123", "secret-12"), false);
  assert.equal(await constantTimeTokenEqual("", ""), false);
});

test("extractBearerToken parses case-insensitive Bearer headers", () => {
  assert.equal(extractBearerToken("Bearer abc.xyz"), "abc.xyz");
  assert.equal(extractBearerToken("  bearer  token-99  "), "token-99");
  assert.equal(extractBearerToken("Basic abc"), "");
  assert.equal(extractBearerToken(null), "");
});

test("authorizeRole respects shared AUTH_TOKEN and role-specific overrides", async () => {
  const makeReq = (token: string) =>
    new Request("https://example.workers.dev/v1/health", {
      headers: { Authorization: `Bearer ${token}` },
    });

  const sharedEnv = { AUTH_TOKEN: "shared-secret" };
  assert.equal(await authorizeRole(makeReq("shared-secret"), sharedEnv, "client"), true);
  assert.equal(await authorizeRole(makeReq("shared-secret"), sharedEnv, "vps"), true);
  assert.equal(await authorizeRole(makeReq("wrong"), sharedEnv, "client"), false);

  const splitEnv = {
    AUTH_TOKEN: "shared-secret",
    CLIENT_AUTH_TOKEN: "iphone-secret",
    VPS_AUTH_TOKEN: "vps-secret",
  };
  assert.equal(await authorizeRole(makeReq("iphone-secret"), splitEnv, "client"), true);
  assert.equal(await authorizeRole(makeReq("vps-secret"), splitEnv, "client"), false);
  assert.equal(await authorizeRole(makeReq("vps-secret"), splitEnv, "vps"), true);
  assert.equal(await authorizeRole(makeReq("iphone-secret"), splitEnv, "vps"), false);
});
