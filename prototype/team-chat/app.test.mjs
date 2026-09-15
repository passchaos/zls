import test from "node:test";
import assert from "node:assert/strict";
import { applyInlineMarkup, buildOutgoingMessage, filterMessages, nextReactionCount, normalizeChannelName, visibleMemberCount } from "./app.js";

test("normalizes channel names", () => {
  assert.equal(normalizeChannelName("  Release Planning!  "), "release-planning");
});

test("filters messages case-insensitively", () => {
  assert.deepEqual(filterMessages(["Maya shipped it", "Liam reviewed it"], "MAYA"), [true, false]);
});

test("toggles reaction counts safely", () => {
  assert.equal(nextReactionCount(4, true), 3);
  assert.equal(nextReactionCount(0, true), 0);
  assert.equal(nextReactionCount(2, false), 3);
});

test("reports collapsed and expanded member counts", () => {
  assert.equal(visibleMemberCount(false, 12), 4);
  assert.equal(visibleMemberCount(true, 12), 12);
});

test("applies inline formatting around a selection", () => {
  assert.deepEqual(applyInlineMarkup("Ship this", 5, 9, "bold"), {
    value: "Ship **this**",
    selectionStart: 7,
    selectionEnd: 11,
  });
});

test("builds messages with optional attachments", () => {
  assert.equal(buildOutgoingMessage(" Ready to ship ", "release.pdf"), "Ready to ship\n📎 release.pdf");
  assert.equal(buildOutgoingMessage("", "release.pdf"), "📎 release.pdf");
  assert.equal(buildOutgoingMessage("   "), "");
});
