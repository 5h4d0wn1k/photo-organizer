"use strict";

// Tests for scripts/project_board_graphql.js. Run with:
//   node --test scripts/tests/project_board_graphql_test.js
//
// These exist because the functions under test used to live inline in
// .github/workflows/project.yml, where nothing could exercise them. Two of the
// cases below -- a match on page three, and a pageInfo that claims another
// page exists but supplies no cursor -- are bugs the single-page original
// either could not express or would have spun on.

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  closingIssueNumbers,
  findItemId,
  MAX_PAGES,
} = require("../project_board_graphql.js");

/**
 * A stand-in for github.graphql that serves `pages` in order and records how
 * it was called, so a test can assert the cursor was threaded correctly and
 * that no request was made after the answer was known.
 */
function fakeGraphql(pages) {
  const calls = [];
  const graphql = async (query, variables) => {
    calls.push({ query, variables });
    const page = pages[calls.length - 1];
    if (page === undefined) {
      throw new Error(`unexpected request ${calls.length}`);
    }
    return { node: page };
  };
  return { graphql, calls };
}

function itemPage(itemIds, { hasNextPage = false, endCursor = null } = {}) {
  return {
    items: {
      nodes: itemIds.map((id) => ({ id: `ITEM_${id}`, content: { id } })),
      pageInfo: { hasNextPage, endCursor },
    },
  };
}

// --- closingIssueNumbers ---------------------------------------------------

test("an unset CLOSING_REFS closes nothing", () => {
  assert.deepEqual(closingIssueNumbers({}), []);
  assert.deepEqual(closingIssueNumbers({ CLOSING_REFS: "" }), []);
  assert.deepEqual(closingIssueNumbers(undefined), []);
});

test("CLOSING_REFS is read as a list of numbers", () => {
  assert.deepEqual(closingIssueNumbers({ CLOSING_REFS: "[12,57]" }), [12, 57]);
});

test("repeated references are collapsed but order is kept", () => {
  assert.deepEqual(closingIssueNumbers({ CLOSING_REFS: "[57,12,57,12]" }), [57, 12]);
});

test("a non-array CLOSING_REFS is rejected rather than iterated", () => {
  // `"12"` would satisfy a naive loop with .map and silently become one number.
  assert.throws(() => closingIssueNumbers({ CLOSING_REFS: '"12"' }), /not an array/);
  assert.throws(() => closingIssueNumbers({ CLOSING_REFS: "null" }), /not an array/);
  assert.throws(() => closingIssueNumbers({ CLOSING_REFS: "{}" }), /not an array/);
});

test("a non-integer member is rejected rather than coerced", () => {
  assert.throws(() => closingIssueNumbers({ CLOSING_REFS: '["12"]' }), /not an array/);
  assert.throws(() => closingIssueNumbers({ CLOSING_REFS: "[12.5]" }), /not an array/);
  assert.throws(() => closingIssueNumbers({ CLOSING_REFS: "[null]" }), /not an array/);
});

test("malformed JSON is rejected rather than swallowed", () => {
  assert.throws(() => closingIssueNumbers({ CLOSING_REFS: "[12," }), SyntaxError);
});

// --- findItemId ------------------------------------------------------------

test("an item on the first page is found with a single query", async () => {
  const { graphql, calls } = fakeGraphql([itemPage(["A", "B"])]);
  assert.equal(await findItemId(graphql, "PVT_1", "B"), "ITEM_B");
  assert.equal(calls.length, 1);
});

test("an item on the second page is found, so the cursor is threaded", async () => {
  const { graphql, calls } = fakeGraphql([
    itemPage(["A", "B"], { hasNextPage: true, endCursor: "CUR1" }),
    itemPage(["C", "D"]),
  ]);
  assert.equal(await findItemId(graphql, "PVT_1", "D"), "ITEM_D");
  assert.equal(calls.length, 2);
  assert.equal(calls[0].variables.cursor, null, "the first page has no cursor");
  assert.equal(calls[1].variables.cursor, "CUR1");
});

test("an item past the first hundred is still found", async () => {
  // The bug the single-page version had: 100 items per page, and the target
  // on page three. With no pagination this returns null and the workflow
  // reports "Item not found on project" for a perfectly valid reference.
  const { graphql } = fakeGraphql([
    itemPage(["x1"], { hasNextPage: true, endCursor: "CUR1" }),
    itemPage(["x2"], { hasNextPage: true, endCursor: "CUR2" }),
    itemPage(["TARGET"]),
  ]);
  assert.equal(await findItemId(graphql, "PVT_1", "TARGET"), "ITEM_TARGET");
});

test("an absent item returns null instead of throwing", async () => {
  const { graphql } = fakeGraphql([itemPage(["A", "B"])]);
  assert.equal(await findItemId(graphql, "PVT_1", "MISSING"), null);
});

test("hasNextPage without an endCursor stops instead of spinning", async () => {
  const { graphql, calls } = fakeGraphql([
    itemPage(["A"], { hasNextPage: true, endCursor: null }),
  ]);
  assert.equal(await findItemId(graphql, "PVT_1", "MISSING"), null);
  assert.equal(calls.length, 1, "must not re-query with a null cursor forever");
});

test("a board that never ends raises rather than looping until the timeout", async () => {
  const endless = itemPage(["A"], { hasNextPage: true, endCursor: "SAME" });
  const { graphql, calls } = fakeGraphql(new Array(MAX_PAGES + 5).fill(endless));
  await assert.rejects(
    () => findItemId(graphql, "PVT_1", "MISSING"),
    new RegExp(`after ${MAX_PAGES} pages`)
  );
  assert.equal(calls.length, MAX_PAGES);
});

test("a null node is treated as an empty page, not a crash", async () => {
  const { graphql } = fakeGraphql([null]);
  assert.equal(await findItemId(graphql, "PVT_1", "MISSING"), null);
});

test("an item node with no content is skipped rather than matched", async () => {
  // A board item can point at a draft or a deleted issue, where the inline
  // fragment leaves `content` null. Dereferencing that would throw.
  const { graphql } = fakeGraphql([
    { items: { nodes: [{ id: "ITEM_NULL" }, { id: "ITEM_B", content: { id: "B" } }], pageInfo: {} } },
  ]);
  assert.equal(await findItemId(graphql, "PVT_1", "B"), "ITEM_B");
});

test("the query declares the cursor variable it passes", async () => {
  const { graphql, calls } = fakeGraphql([itemPage(["A"])]);
  await findItemId(graphql, "PVT_1", "MISSING");
  // If the variables are passed but not declared, GitHub rejects the query at
  // run time and the workflow only ever warns.
  assert.match(calls[0].query, /\$cursor:\s*String/);
  assert.match(calls[0].query, /after:\s*\$cursor/);
  assert.match(calls[0].query, /pageInfo\s*\{\s*hasNextPage\s+endCursor\s*\}/);
});