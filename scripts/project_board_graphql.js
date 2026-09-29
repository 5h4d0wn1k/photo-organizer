"use strict";

/**
 * Testable parts of the project-board workflow (.github/workflows/project.yml).
 *
 * Both of these used to live inline in a `script:` block, where nothing can
 * exercise them: GitHub runs `script:` as JavaScript, not as a module, so
 * there is no way to import it, fake `github.graphql`, or assert what happens
 * on the third page of a paginated query. They live here so they can be.
 *
 * Nothing in this file touches the network or the filesystem. Everything is
 * injected: `graphql` is passed in, and the environment is passed in as a
 * plain object. That is what makes the suite in
 * scripts/tests/project_board_graphql_test.js possible.
 */

// GraphQL page size for the board's item connection.
const PAGE_SIZE = 100;

// Runaway guard, not a limit we expect to reach: 50 pages is 5000 items. It
// exists so a malformed `pageInfo` -- hasNextPage true with an endCursor that
// never changes -- cannot spin the job until its timeout instead of failing.
const MAX_PAGES = 50;

/**
 * Which issues this pull request closes, as decided by
 * scripts/project_board_refs.py and passed in via CLOSING_REFS.
 *
 * The old version of this was `(body.match(/#(\d+)/g) || [])`, which read
 * *any* `#N` in the body. A sentence like "related to #57" therefore moved
 * this repository's issue #57 to In Review, and to Shipped on merge.
 *
 * @param {Record<string, string | undefined>} env
 * @returns {number[]} de-duplicated issue numbers, in the order given
 */
function closingIssueNumbers(env) {
  const raw = env ? env.CLOSING_REFS : undefined;
  if (!raw) return [];
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed) || parsed.some((n) => !Number.isInteger(n))) {
    throw new Error(`CLOSING_REFS is not an array of integers: ${raw}`);
  }
  return [...new Set(parsed)];
}

/**
 * Find an item on the board by the id of the issue or PR it points at.
 *
 * Paginated on purpose. `items(first: 100)` with no cursor reads only the
 * first page, so once a board passes 100 items the lookup silently misses
 * everything after it -- and this board is already at 57 issues plus their
 * PRs. The single-page version turned that into "Item not found on project"
 * warnings for perfectly valid references.
 *
 * @param {(query: string, variables: Record<string, unknown>) => Promise<any>} graphql
 * @param {string} projectId
 * @param {string} contentId node id of the Issue or PullRequest
 * @returns {Promise<string | null>} the board item id, or null if absent
 */
async function findItemId(graphql, projectId, contentId) {
  let cursor = null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const { node } = await graphql(
      `query($id: ID!, $cursor: String) {
         node(id: $id) {
           ... on ProjectV2 {
             items(first: ${PAGE_SIZE}, after: $cursor) {
               nodes {
                 id
                 content {
                   ... on Issue { id }
                   ... on PullRequest { id }
                   ... on DraftIssue { id }
                 }
               }
               pageInfo { hasNextPage endCursor }
             }
           }
         }
       }`,
      { id: projectId, cursor }
    );
    const connection = (node && node.items) || { nodes: [], pageInfo: {} };
    const item = (connection.nodes || []).find(
      (i) => i && i.content && i.content.id === contentId
    );
    if (item) return item.id;
    if (!connection.pageInfo || !connection.pageInfo.hasNextPage) return null;
    cursor = connection.pageInfo.endCursor;
    if (!cursor) return null; // hasNextPage without a cursor: stop, do not spin.
  }
  throw new Error(
    `gave up looking for ${contentId} after ${MAX_PAGES} pages of the project`
  );
}

module.exports = { closingIssueNumbers, findItemId, PAGE_SIZE, MAX_PAGES };