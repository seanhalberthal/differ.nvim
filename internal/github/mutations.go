package github

// GraphQL mutation documents (and the lookups their methods need). kept apart from
// the read queries in queries.go.

// startReviewLookupQuery fetches the PR node id plus the viewer's existing pending
// review (if any) in one round trip, so start_review can be idempotent.
const startReviewLookupQuery = `
query StartReviewLookup($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      reviews(first: 1, states: [PENDING]) {
        nodes { id }
      }
    }
  }
}`

// addReviewMutation creates a pending review (no event) on the PR.
const addReviewMutation = `
mutation AddReview($prId: ID!) {
  addPullRequestReview(input: {pullRequestId: $prId}) {
    pullRequestReview { id }
  }
}`

// submitReviewMutation finalizes a pending review with an event (APPROVE /
// REQUEST_CHANGES / COMMENT) and optional body.
const submitReviewMutation = `
mutation SubmitReview($reviewId: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: {pullRequestReviewId: $reviewId, event: $event, body: $body}) {
    pullRequestReview { fullDatabaseId }
  }
}`

// deleteReviewMutation discards a pending review and its unsubmitted comments.
const deleteReviewMutation = `
mutation DeleteReview($reviewId: ID!) {
  deletePullRequestReview(input: {pullRequestReviewId: $reviewId}) {
    pullRequestReview { id }
  }
}`

// prNodeIDQuery resolves a PR's GraphQL node id, the anchor an immediate (non-draft)
// review thread is attached to.
const prNodeIDQuery = `
query PRNodeID($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) { id }
  }
}`

// addThreadMutation opens a new review thread. exactly one of $prId / $reviewId is
// passed: $reviewId joins a pending draft, $prId posts immediately on the PR. line/
// side anchor the end of the range, startLine/startSide the start of a multi-line
// range (null for single-line; cross-side ranges are valid, §7.5).
const addThreadMutation = `
mutation AddThread($prId: ID, $reviewId: ID, $path: String!, $body: String!, $line: Int!, $side: DiffSide!, $startLine: Int, $startSide: DiffSide) {
  addPullRequestReviewThread(input: {pullRequestId: $prId, pullRequestReviewId: $reviewId, path: $path, body: $body, line: $line, side: $side, startLine: $startLine, startSide: $startSide}) {
    thread {
      id
      comments(first: 1) { nodes { fullDatabaseId } }
    }
  }
}`

// addThreadReplyMutation replies into an existing thread; $reviewId joins the reply
// to that pending draft, omitting it posts the reply immediately.
const addThreadReplyMutation = `
mutation AddThreadReply($threadId: ID!, $reviewId: ID, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, pullRequestReviewId: $reviewId, body: $body}) {
    comment { fullDatabaseId }
  }
}`

// resolveThreadMutation / unresolveThreadMutation toggle a thread's resolved state.
// the mutation field is aliased to result so both decode into one shape.
const resolveThreadMutation = `
mutation Resolve($threadId: ID!) {
  result: resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}`

const unresolveThreadMutation = `
mutation Unresolve($threadId: ID!) {
  result: unresolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}`
