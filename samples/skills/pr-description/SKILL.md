---
name: pr-description
description: Writes a reviewer-ready pull request title and description from `git diff base...HEAD` and the branch's commits, covering what changed, why, how it was tested, risk and rollback. Detects the correct base branch (including stacked branches), fills the repo's PR template if one exists, and writes markdown ready for `gh pr create --body-file`. Use when the user says "write the PR description", "draft a PR", "PR body", "open a PR for this branch", or "summarize this branch for review".
---

# PR description

Write for the reviewer, who has 5 minutes and no context. They should finish the description knowing what changed, why, where to look hardest, and how confident to be.

Never claim anything you cannot back up from the diff, the commits, the linked issue, or what happened in this session.

## 1. Find the base

In order:
1. The user named one. Use it.
2. A PR already exists: `gh pr view --json baseRefName,number,url -q .baseRefName`. In that case you will `gh pr edit`, not create.
3. The repo default: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`, or `git symbolic-ref --short refs/remotes/origin/HEAD`.
4. **Stacked-branch check.** If the branch was cut from another feature branch, the default base shows that branch's commits too. Compare the candidates:
   ```bash
   git fetch origin --quiet
   for b in $(git for-each-ref --sort=-committerdate --count=40 --format='%(refname:short)' refs/remotes/origin); do
     [ "$b" = origin/HEAD ] && continue
     git merge-base --is-ancestor HEAD "$b" && continue   # already contains this branch (e.g. its own upstream)
     printf '%s %s\n' "$(git rev-list --count "$b"..HEAD)" "$b"
   done | sort -n | head -5
   ```
   A feature branch with far fewer commits ahead than `main` is probably the real parent. Confirm with the user before using a non-default base.

Always diff against `origin/<base>` after a fetch. A stale local `main` produces a description full of other people's changes.

## 2. Gather

```bash
B=origin/<base>
git log --reverse --format='--- %h %s%n%b' $B..HEAD
git diff --stat $B...HEAD
git diff $B...HEAD -- . ':(exclude)*.lock' ':(exclude)*-lock.*' ':(exclude)*.snap' ':(exclude)**/generated/**'
```

- Three dots (`A...B`) diff against the merge-base, which is exactly what the PR will show. Two dots would include changes that landed on the base since you branched.
- On large diffs, read `--stat` first. Then read the files that carry the logic in full. Skim tests, and only note the lockfile, generated and snapshot files.
- **Context sources**: the issue key in the branch name (`feat/PAY-412-...`), `Fixes #123` / `Closes` in commits, and `gh issue view 123 --json title,body` if the issue is on GitHub. Code comments added in the diff often state the why.
- **PR template**: look for `.github/pull_request_template.md`, `.github/PULL_REQUEST_TEMPLATE/*.md`, `docs/pull_request_template.md` and `PULL_REQUEST_TEMPLATE.md`. If one exists, **fill it**. Keep its headings, checkboxes and order, and tick a box only when it is true. Use the format below only when no template exists.
- **Title convention**: `git log --format=%s -30 $B`. Match what the repo does (Conventional Commits `feat(api): ...`, ticket prefix `[PAY-412]`, or plain imperative).

## 3. Work out the substance

- **What.** Describe behavior, not files. Group the changes by concern ("Invoices now store the customer's timezone", "Backfill job for existing invoices"), not as a per-file changelog. Two to six bullets.
- **Why.** Take it from the issue, the commits or the comments. If you cannot find it, **do not invent it**. Ask the user one direct question ("What prompted this? A bug report, a customer, a perf issue?"), or leave a visible `TODO(author): why?` in the draft.
- **How tested.** List only what has evidence:
  - tests added or changed in the diff, named;
  - commands run **in this session**, with their results;
  - manual testing, only if the user told you they did it.

  If nothing was run, say so and offer to run the suite. "Tested locally" with no evidence is worse than an honest gap.
- **Risk.** Scan for the things that break production and name each one found:
  - DB migrations: locking, backfills, ordering. Suggest the `migration-review` skill.
  - New or renamed env vars and config keys. Deploy fails if they are not set.
  - Public API, event schema or serialization changes. Existing clients may break.
  - Auth, permission and tenant-scoping code.
  - Caching and invalidation, concurrency and retries.
  - Dependency additions and major upgrades.
  - Feature flags: name them and their default.
  - Performance-sensitive paths: hot loops, list endpoints, queries without limits.

  Then give a one-line blast radius: who or what is affected if this is wrong.
- **Rollback.** Say whether "revert the PR" is actually safe. It is **not** safe when:
  - a migration dropped or rewrote data;
  - new code writes data in a format the old code cannot read;
  - external side effects already happened (emails, webhooks, charges);
  - a flag or config change must be reverted too.

  In those cases, write the real steps.
- **Reviewer guidance.** Name the one or two places that deserve the most scrutiny, with paths, and anything intentionally left out of scope.

## 4. Write it

Write it tight, specific and plain. Skip marketing words ("robust", "seamless", "enhanced"), line-by-line narration of the diff, and filler sections: leave a section out rather than writing "N/A", except Risk and Rollback, which always appear.

```markdown
## Summary
<1-3 sentences: what this PR does and why, in user or system terms.>

Closes #123 <!-- only if there is a real reference -->

## Changes
- <behavioral change, grouped by concern>
- <...>

## Why
<Motivation or context. Link the issue, incident or discussion.>

## How tested
- `<command>`: <result> <!-- e.g. `pytest tests/billing` - 48 passed -->
- Added `<test name>` covering <case>
- <manual steps, only if the user confirmed them>

## Risk
<Level: low / medium / high>. <Specific risks found, or "No migrations, config, or API changes.">

## Rollback
<"Safe to revert." or the exact steps: disable flag X, run down-migration Y, etc.>

## Reviewer notes
- Start with `<path>`: <why>
- Out of scope: <thing deliberately not done>
```

For UI changes, add `## Screenshots` with before/after placeholders and tell the user to attach images. Do not fabricate them.

## 5. Save it and hand off

```bash
BODY="$(git rev-parse --git-dir)/PR_BODY.md"   # inside .git, so it can never be committed by accident
```

Write the body there with the Write tool, then show the user the title and the path.

Give the user the exact command, but **do not run it unless they ask**. Opening a PR notifies people and is public inside the org:

```bash
gh pr create --base <base> --title "<title>" --body-file "$(git rev-parse --git-dir)/PR_BODY.md"      # add --draft if WIP
gh pr edit <number> --body-file "$(git rev-parse --git-dir)/PR_BODY.md"                              # existing PR
```

If the branch is not pushed yet (`git rev-parse --abbrev-ref @{u}` fails), mention that `gh pr create` will ask to push, or that the user can push first with `git push -u origin HEAD`.

## Report

Reply with:
1. The proposed title.
2. The body file path, and the full markdown body in a fenced block so the user can review it inline.
3. Open questions you could not answer from evidence: why, manual testing, rollout.
4. The `gh` command to run.
