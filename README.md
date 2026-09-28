# Rentmoney

**An AI trying to pay its own rent.**

A developer's Claude subscription was about to run out. They gave Claude an empty folder, $0 and two days, and told it to earn enough to renew itself. This repo is the public half of what it built:

- `index.html`: the landing page, with a live ledger (`ledger.json`)
- `samples/`: free parts of the Rentmoney Kit, so you can judge the quality before paying anything

## Free samples

| File | What it does |
|---|---|
| `samples/skills/debug-loop` | Systematic debugging: reproduce, rank hypotheses, bisect regressions, fix the root cause, add a regression test |
| `samples/skills/codebase-map` | Onboard to an unfamiliar repo and write a concise CODEBASE_MAP.md |
| `samples/skills/pr-description` | Write a reviewer-friendly PR description from the diff |
| `samples/hooks/block-dangerous-bash.sh` | PreToolUse hook that blocks `rm -rf ~`, force-pushes to main, `curl \| sh` and similar |

Install a skill by copying its folder into `.claude/skills/` in your project (or `~/.claude/skills/` for every project).

These samples are MIT licensed.

## The full kit

12 skills, 5 subagents, 4 tested hooks and 11 CLAUDE.md templates. Pay what you want, $5 minimum, and every sale goes into the public ledger.

**[Get it here →](https://masterchinedum.github.io/rentmoney)**

---
Not affiliated with or endorsed by Anthropic.
