/**
 * Shared Codex review detection.
 *
 * Only comments/reviews authored by chatgpt-codex-connector[bot] are trusted.
 * A finding is actionable only when the current head commit has a P0/P1 line
 * that is not a "running", "zero findings" or "no issues" status.
 */
const crypto = require('crypto');
const fs = require('fs');

const CODEX_LOGIN = 'chatgpt-codex-connector[bot]';
const MARKER_RE =
  /<!--\s*opencode-autofix\s+attempt=(\d+)\s+sha=([0-9a-f]{7,40})\s+findings=([0-9a-f]{6,64})\s*-->/gi;
const TRUSTED_ASSOCIATIONS = new Set(['OWNER', 'MEMBER', 'COLLABORATOR']);
const TRUSTED_BOTS = new Set(['github-actions[bot]', 'opencode-agent[bot]']);

function normalize(text) {
  return String(text || '').replace(/\r\n/g, '\n').trim();
}

function sameSha(a, b) {
  const left = String(a || '').toLowerCase();
  const right = String(b || '').toLowerCase();
  if (!left || !right) return false;
  if (left === right) return true;
  return (left.length >= 7 && right.startsWith(left)) ||
    (right.length >= 7 && left.startsWith(right));
}

/**
 * Codex summary comments embed the reviewed SHA both in a hidden JSON state
 * block and in the visible "Reviewed commit" line. A summary that cannot be
 * tied to the current head must not contribute actionable text.
 */
function extractReviewSha(text) {
  const body = normalize(text);
  let match = /"commit_sha"\s*:\s*"([0-9a-f]{40})"/i.exec(body);
  if (match) return match[1].toLowerCase();
  match = /\breviewed commit\b[^\n]{0,40}?([0-9a-f]{7,40})\b/i.exec(body);
  return match ? match[1].toLowerCase() : null;
}

function findingsHash(text) {
  return crypto.createHash('sha256').update(normalize(text)).digest('hex').slice(0, 12);
}

function isStatusLine(line) {
  return /\b(will appear|will be posted|running|in progress|pending|queued|started|analyzing|scanning|reviewing)\b/i.test(line);
}

const NEGATIVE_PHRASES =
  /\b(no actionable|LGTM|looks good|did not find|didn'?t find|did not identify|didn'?t identify)\b/i;
const COMBINED_NEGATIVE =
  /\b(p0|p1)\s*\/\s*(p0|p1)\s*[:=]\s*(0|none|no|nothing)\b/i;
const GLOBAL_NEGATIVE =
  /\b(no|zero|none|without|0)\s+(p0|p1)(?:\s*\/\s*(p0|p1))?\b/i;

/**
 * A line can contain both a zero and a real finding, for example
 * "P0: 0, P1: 2". Evaluate each token separately instead of treating the
 * whole line as negative.
 */
function tokenIsNegative(line, token) {
  const tokenRe = new RegExp(`\\b${token}\\b`, 'i');
  if (!tokenRe.test(line)) return true;
  const explicitZero = new RegExp(
    `\\b${token}\\b\\s*[:=]\\s*(0|none|no|nothing)\\b`, 'i',
  );
  if (explicitZero.test(line)) return true;
  const zeroBefore = new RegExp(
    `\\b(0|no|zero|none|without)\\s+${token}\\b`, 'i',
  );
  return zeroBefore.test(line);
}

function lineHasFinding(line) {
  if (isStatusLine(line)) return false;
  if (NEGATIVE_PHRASES.test(line) || COMBINED_NEGATIVE.test(line) ||
      GLOBAL_NEGATIVE.test(line)) return false;
  return ['p0', 'p1'].some((token) =>
    new RegExp(`\\b${token}\\b`, 'i').test(line) && !tokenIsNegative(line, token),
  );
}

function countFindings(text) {
  const lines = normalize(text).split('\n');
  const hits = [];
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    if (lineHasFinding(line)) {
      hits.push(line.slice(0, 400));
    }
  }
  return { count: hits.length, hits };
}

function isStatusOnly(text) {
  const body = normalize(text);
  if (!body) return false;
  if (countFindings(body).count > 0) return false;
  return /\b(running|in progress|will appear|will be posted|queued|started|analyzing|scanning|reviewing)\b/i.test(body);
}

function hasActionableFindings(text) {
  return countFindings(text).count > 0;
}

function fixtureText(name) {
  switch (String(name || '').toLowerCase()) {
    case 'p0':
      return '## Codex Review\n\n### P0\n1. Bank waterline is 4 m below the sheet.\n\n### P1\n2. Water and bank trims differ.';
    case 'p1':
      return 'Codex Review\n\nP1 — Junction dedupe threshold is 2 m instead of 2 mm.';
    case 'zero':
      return 'Codex Review\n\nP0: 0\nP1: 0\nNo actionable findings.';
    case 'running':
      return 'Codex is running. Review in progress; findings will appear below.';
    case 'live':
      return '';
    case 'none':
    default:
      return 'Codex Review\n\nNo P0/P1 issues found. LGTM.';
  }
}

function trustedAuthor(pr, owner) {
  if (TRUSTED_ASSOCIATIONS.has(pr.author_association)) return true;
  if (pr.user && pr.user.login === owner) return true;
  return !!(pr.user && TRUSTED_BOTS.has(pr.user.login));
}

function buildPrompt(pr, sha, findings, reviewUrl) {
  const excerpt = normalize(findings).slice(0, 12000);
  return `You are fixing Codex review findings on PR #${pr} in this repository.

Current head commit: ${sha}
Codex review: ${reviewUrl || 'see pull request reviews'}

Rules:
- Address only actionable P0/P1 findings listed below.
- Do not run git commit, git push, git merge, or gh pr create/merge. Leave all
  changes uncommitted in the working tree; the workflow will commit and push
  them to the current pull request branch after you finish.
- Do not modify .github/workflows/ or .github/scripts/.
- Run relevant checks you can run (at minimum \`./Scripts/build.sh\`; do not claim a test passed unless it did).
- If a finding is invalid, needs a product decision, or requires an unavailable environment, explain it in your final message instead of making a risky change.
- Do not modify unrelated files.

Codex findings:
${excerpt}`;
}

async function detect({ github, context, core }) {
  const { owner, repo } = context.repo;
  const isDispatch = context.eventName === 'workflow_dispatch';
  const inputs = context.payload.inputs || {};
  const fixtureName = isDispatch ? String(inputs.fixture || 'live') : '';
  // A manual "live" dispatch is a real detection, not a parser fixture.
  const useFixture = isDispatch && fixtureName !== 'live';
  const fixture = useFixture ? fixtureName : '';
  let prNumber;
  let reviewedSha = null;
  let eventBody = '';

  if (context.eventName === 'pull_request') {
    const sender = context.payload.sender?.login;
    if (sender && sender !== CODEX_LOGIN) {
      // A human push to the PR is still useful: it lets a re-run of this
      // detector evaluate reviews that already exist for the new head SHA.
      core.info(`pull_request sender is ${sender}; evaluating current head only`);
    }
    prNumber = context.payload.pull_request.number;
  } else if (context.eventName === 'pull_request_review') {
    if (context.payload.sender?.login !== CODEX_LOGIN) {
      core.info('sender is not the Codex bot');
      return;
    }
    prNumber = context.payload.pull_request.number;
    reviewedSha = context.payload.review.commit_id;
    eventBody = context.payload.review.body || '';
  } else if (context.eventName === 'pull_request_review_comment') {
    if (context.payload.sender?.login !== CODEX_LOGIN) {
      core.info('sender is not the Codex bot');
      return;
    }
    prNumber = context.payload.pull_request.number;
    reviewedSha = context.payload.comment.commit_id;
    eventBody = context.payload.comment.body || '';
  } else if (context.eventName === 'issue_comment') {
    if (!context.payload.issue.pull_request) {
      core.info('issue comment is not on a pull request');
      return;
    }
    if (context.payload.sender?.login !== CODEX_LOGIN) {
      core.info('sender is not the Codex bot');
      return;
    }
    prNumber = context.payload.issue.number;
    eventBody = context.payload.comment.body || '';
    reviewedSha = extractReviewSha(eventBody);
    if (!reviewedSha) {
      core.info('summary comment has no reviewed SHA; ignoring its text');
      eventBody = '';
    }
  } else if (isDispatch) {
    prNumber = Number(inputs.pr);
  } else {
    core.info(`unsupported event ${context.eventName}`);
    return;
  }

  if (!Number.isInteger(prNumber) || prNumber <= 0) {
    core.info('missing pull request number');
    return;
  }

  if (!isDispatch &&
      (context.eventName === 'pull_request_review' ||
       context.eventName === 'pull_request_review_comment') &&
      !reviewedSha) {
    core.info('review has no commit_id; cannot verify it is current');
    return;
  }

  if (!isDispatch && isStatusOnly(eventBody)) {
    core.info('event is a running status with no findings');
    return;
  }

  const { data: pr } = await github.rest.pulls.get({
    owner, repo, pull_number: prNumber,
  });

  if (pr.state !== 'open') {
    core.info('pull request is not open');
    return;
  }
  if (pr.head.repo?.full_name !== `${owner}/${repo}`) {
    core.info('fork PR rejected');
    return;
  }
  if (pr.base.ref !== 'main') {
    core.info('only PRs targeting main are automated');
    return;
  }
  if (pr.head.ref === 'main' || pr.head.ref === 'master') {
    core.info('refusing a PR whose head is the default branch');
    return;
  }
  if (!trustedAuthor(pr, owner)) {
    core.info(`untrusted PR author: ${pr.user?.login} (${pr.author_association})`);
    return;
  }

  const headSha = pr.head.sha;
  if (reviewedSha && !sameSha(reviewedSha, headSha)) {
    core.info(`stale review: ${reviewedSha} != ${headSha}`);
    return;
  }

  if (context.eventName === 'issue_comment' && !isDispatch) {
    const { data: commit } = await github.rest.repos.getCommit({
      owner, repo, ref: headSha,
    });
    const committedAt = Date.parse(commit.commit.committer.date);
    const updatedAt = Date.parse(
      context.payload.comment.updated_at || context.payload.comment.created_at,
    );
    if (Number.isFinite(committedAt) && Number.isFinite(updatedAt) &&
        updatedAt + 5000 < committedAt) {
      core.info('summary comment is older than the current head commit');
      return;
    }
  }

  const reviews = await github.paginate(github.rest.pulls.listReviews, {
    owner, repo, pull_number: prNumber, per_page: 100,
  });
  const reviewComments = await github.paginate(
    github.rest.pulls.listReviewComments,
    { owner, repo, pull_number: prNumber, per_page: 100 },
  );

  const codexReviews = reviews.filter(
    (r) => r.user?.login === CODEX_LOGIN && r.commit_id === headSha,
  );
  const codexComments = reviewComments.filter(
    (c) => c.user?.login === CODEX_LOGIN && c.commit_id === headSha,
  );

  // Attempt markers and Codex summary updates both live in issue comments.
  // A summary is trusted only when it names the current head SHA.
  const issueComments = await github.paginate(github.rest.issues.listComments, {
    owner, repo, issue_number: prNumber, per_page: 100,
  });
  const codexIssueComments = issueComments.filter((c) =>
    c.user?.login === CODEX_LOGIN &&
    sameSha(extractReviewSha(c.body || ''), headSha));

  const seen = new Set();
  const parts = [];
  const addText = (value) => {
    const text = normalize(value);
    if (!text || seen.has(text)) return;
    seen.add(text);
    parts.push(text);
  };

  if (useFixture) {
    addText(fixtureText(fixture));
  } else {
    addText(eventBody);
    for (const review of codexReviews) addText(review.body || '');
    for (const comment of codexComments) addText(comment.body || '');
    for (const comment of codexIssueComments) addText(comment.body || '');
  }

  const combined = parts.join('\n\n---\n\n');
  const count = countFindings(combined).count;
  const hasFindings = count > 0;

  let attempts = 0;
  let sameShaAndFindings = false;
  for (const comment of issueComments) {
    const body = comment.body || '';
    for (const match of body.matchAll(MARKER_RE)) {
      const attempt = Number(match[1]);
      const sha = match[2];
      const markerHash = match[3].toLowerCase();
      if (Number.isFinite(attempt)) attempts = Math.max(attempts, attempt);
      if (sameSha(sha, headSha) && markerHash === findingsHash(combined)) {
        sameShaAndFindings = true;
      }
    }
  }

  const maxAttempts = Math.max(
    1,
    Number(process.env.OPENCODE_AUTOFIX_MAX || inputs.max_attempts || 2),
  );
  const maxed = attempts >= maxAttempts;
  const shouldFix = hasFindings && !sameShaAndFindings && !maxed;
  const attempt = Math.min(attempts + 1, maxAttempts);
  const hash = findingsHash(combined);
  const reviewUrl = codexReviews[0]?.html_url ||
    codexComments[0]?.html_url ||
    `https://github.com/${owner}/${repo}/pull/${prNumber}`;

  const payload = {
    should_fix: shouldFix,
    test: useFixture,
    pr: prNumber,
    sha: headSha,
    head_ref: pr.head.ref,
    base_ref: pr.base.ref,
    attempt,
    max_attempts: maxAttempts,
    maxed,
    same_findings: sameShaAndFindings,
    findings_count: count,
    findings_hash: hash,
    findings_excerpt: combined.slice(0, 6000),
    prompt: shouldFix ? buildPrompt(prNumber, headSha, combined, reviewUrl) : '',
    review_url: reviewUrl,
  };

  core.setOutput('should_fix', String(shouldFix));
  core.setOutput('test', String(useFixture));
  core.setOutput('pr', String(prNumber));
  core.setOutput('sha', headSha);
  core.setOutput('head_ref', pr.head.ref);
  core.setOutput('attempt', String(attempt));
  core.setOutput('max_attempts', String(maxAttempts));
  core.setOutput('findings_count', String(count));
  core.setOutput('findings_hash', hash);
  core.setOutput('maxed', String(maxed));
  core.setOutput('same_findings', String(sameShaAndFindings));

  const outputPath = process.env.CODEX_FINDINGS_OUTPUT || 'codex-findings.json';
  fs.writeFileSync(outputPath, `${JSON.stringify(payload, null, 2)}\n`);

  core.summary
    .addHeading('Codex finding detection')
    .addTable([
      [{ data: 'Field', header: true }, { data: 'Value', header: true }],
      ['PR', `#${prNumber} (${pr.head.ref} -> ${pr.base.ref})`],
      ['Head SHA', headSha],
      ['Actionable P0/P1 lines', String(count)],
      ['Attempts used', `${attempts}/${maxAttempts}`],
      ['Same findings already attempted', String(sameShaAndFindings)],
      ['Max reached', String(maxed)],
      ['Should fix', String(shouldFix)],
      ['Test mode', String(useFixture)],
    ]);
  if (count > 0) {
    core.summary.addHeading('Findings', 3).addCodeBlock(
      combined.slice(0, 6000), 'text',
    );
  }
  await core.summary.write();

  core.info(`should_fix=${shouldFix} count=${count} attempts=${attempts}/${maxAttempts}`);
}

module.exports = {
  CODEX_LOGIN,
  detect,
  hasActionableFindings,
  countFindings,
  extractReviewSha,
  findingsHash,
  fixtureText,
  isStatusOnly,
  sameSha,
};
