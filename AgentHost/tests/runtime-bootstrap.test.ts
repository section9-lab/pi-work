import { expect, mock, test } from "bun:test";

let oauthRegistrationCount = 0;

mock.module("@earendil-works/pi-ai/bun-oauth", () => ({
  registerBunOAuthFlows: () => {
    oauthRegistrationCount += 1;
  },
}));

test("registers bundled OAuth flows when the Agent Host starts", async () => {
  await import("../src/main.ts");

  expect(oauthRegistrationCount).toBe(1);
  expect(Bun.env.PI_WORK_AGENT_HOST).toBe("1");
});
