---
name: debug-loop
description: Systematic debugging for bugs, failing tests, crashes, flaky behavior and regressions. Reproduces first with a failing test or script, forms ranked hypotheses and tests them cheaply, uses git bisect for regressions, fixes the root cause instead of the symptom, and adds a regression test. Has hard rules against guess-and-check thrashing. Use when the user says "debug this", "why is this failing", "this broke", "flaky test", "it used to work", or pastes an error or stack trace.
---

# Debug loop

Debugging is evidence gathering. Every edit you make should either produce evidence or apply a fix that the evidence already justifies. If you catch yourself editing code "to see if it helps", stop. That is the failure mode this skill exists to prevent.

## 0. Pin down the report

Before touching code, write down:
- **Exact symptom**: the full error message and stack trace, or the wrong output next to the expected output. Symptoms like "doesn't work" or "is broken" are not symptoms yet.
- **Trigger**: the input, command, request or user action.
- **Environment**: branch/commit (`git rev-parse --short HEAD`), runtime versions (`node -v`, `python -V`, `go version`), OS, and config/env that differs from where it works.
- **Frequency**: always, sometimes (roughly how often), or only in CI/prod.
- **Last known good**, if any: a tag, a date, a deploy.

If any of these are unknowable from the conversation and the repo, ask the user once, with specific questions.

## 1. Reproduce before anything else

- Write the **smallest automated repro**. Prefer a failing test in the project's own framework, placed where the eventual regression test belongs. Fall back to a standalone script in the scratchpad.
- Run it and confirm it fails **for the reported reason**. A test that fails on a typo in the test is not a repro.
- **Intermittent failures**: loop until you have a failure rate.
  ```bash
  for i in $(seq 1 50); do <test cmd> >/tmp/run.$i.log 2>&1 || echo "FAIL $i"; done
  go test -run TestX -count=200 -race ./pkg/...
  pytest tests/test_x.py::test_y -p no:randomly --count=50   # needs pytest-repeat
  ```
  Flaky usually means shared state between tests (order-dependent), time/timezone, randomness, concurrency, or network. Try running the test alone versus in the full suite, and shuffled (`pytest -p randomly`, `jest --randomize`, `go test -shuffle=on`).
- **Cannot reproduce after a real attempt** (about 3 approaches)? Do not fix blind. Report what you tried, then either ask for more evidence (logs, exact data, prod versions) or add targeted instrumentation so the next occurrence captures the state you need.

## 2. Read the evidence you already have

- Read the **whole** error. In Python, the last traceback line is the error and the frames above show the path. Java/Kotlin: read the deepest `Caused by:`. JS: find the first stack frame in the project's own code, not in `node_modules`. Go: read the first goroutine that panicked, not the thousands that follow.
- When there are many errors, the **first** one is usually the cause and the rest are fallout.
- Ask what changed:
  ```bash
  git log --oneline --since="2 weeks ago" -- <suspect paths>
  git diff <last-good>..HEAD --stat
  git diff <last-good>..HEAD -- package-lock.json poetry.lock go.sum Cargo.lock   # dependency drift
  ```
  Also check config and env vars, data shape (a new customer's weird input), infrastructure, and the date (DST, month end, leap day, year boundary).

## 3. Hypotheses: ranked, with predictions

Write 2 to 4 hypotheses. For each one, record:
- the claim ("`user.tz` is null for SSO users created before the migration"),
- the **prediction** that would confirm or kill it ("if true, the failing request's user row has `tz IS NULL`"),
- the **cheapest experiment** that tests it: a query, a log line, a debugger breakpoint, one assertion.

Rank them by likelihood × cheapness, and run the experiment that best **splits** the hypotheses, not the one that confirms your favourite.

Techniques, cheapest first:
- **Tagged prints.** Every temporary log line gets a unique tag so cleanup is one grep: `print("DBGLOOP", repr(x))` / `console.error("DBGLOOP", x)`.
- **Debugger.** Use `python -m pdb -c continue`, `node --inspect-brk`, `dlv test ./pkg -- -test.run TestX`, or `rust-lldb`. Set a breakpoint at the point where the value first goes wrong.
- **Halve the input.** Delta-debug a failing payload or file: cut it in half until the minimal failing input remains.
- **Halve the code path.** Assert the invariant in the middle of the pipeline. Is it already broken there?
- **Compare with a working case.** Put the same request through a working user, environment or commit side by side and diff the logs.
- **Confirm your edits run at all.** Put a deliberate `raise`/`throw` in the code you think is running. More debugging time goes to stale builds, a wrong entrypoint and caches than to hard bugs. Clear the caches when in doubt: `rm -rf .next node_modules/.cache`, `find . -name __pycache__ -exec rm -rf {} +`, `go clean -testcache`, `jest --clearCache`, and restart dev servers and workers.

## 4. Regressions: bisect, don't read

If it worked at a known commit or tag, bisect instead of theorising:

```bash
git bisect start <bad-sha-or-HEAD> <good-sha-or-tag>
git bisect run /path/outside/repo/repro.sh
git bisect log > /tmp/bisect.log; git bisect reset
```

`repro.sh` must exit 0 for good, 1 to 124 for bad, and **125 for "cannot test this commit"** (for example, it does not build for an unrelated reason). Keep it outside the working tree so checkouts do not change it. If the lockfile changes across the range, reinstall dependencies inside the script (`npm ci --silent`, `uv sync -q`). If there is no known-good commit, try the last release: `git describe --tags --abbrev=0`. Bisect names a commit, not a cause. Read that commit's diff with your hypotheses in hand.

## 5. Anti-thrashing rules (hard)

1. **One change per experiment.** Revert any experiment that did not pan out before starting the next one. Commit or stash known-good checkpoints so `git diff` shows only the current experiment.
2. **After 2 failed fix attempts, stop editing.** Revert to clean. Write down what you know, what you have ruled out and what you assumed without checking. Then go back to step 2 or 3 and gather new evidence. The usual cause is an unverified assumption: the code path runs, the config loaded, the data looks like you think it does.
3. **After 4 failed attempts, or about 45 minutes without new evidence, stop and report** to the user with the evidence log and your best current hypothesis. Ask for direction or data.
4. **Banned "fixes"** unless the evidence says they are the root-cause fix:
   - try/catch that swallows the error,
   - a sleep or retry to paper over a race,
   - a raised timeout,
   - `@ts-ignore` / `# type: ignore` / `nolint`,
   - editing the test's expected value to match the wrong output,
   - skipping the test,
   - pinning a random dependency version, or
   - "clean reinstall and hope".
5. **"It works now" is not done.** If you cannot explain why the fix works, you have not found the root cause. Keep going, or say so explicitly.

## 6. Fix the root cause

- Trace backwards from the symptom: where did the bad value **first** appear, and which invariant broke there? Fix that point. Add validation at the symptom site only when it is a trust boundary (user input, external API).
- Look for siblings: `rg -n '<the same pattern>'`. The same mistake often exists in 3 places.
- Keep the fix minimal. Refactors you want to make go in a separate commit after the fix.
- If the root cause is in a dependency, work around it locally with a comment linking the upstream issue, and tell the user.

## 7. Lock it in

- Turn the repro into a regression test named for the behavior (`test_invoice_total_uses_user_timezone`), not for the ticket number.
- **Prove the test works**: stash the fix (`git stash push -- <fix files>`), run the test and watch it fail, then `git stash pop` and watch it pass.
- Run the surrounding suite. For a flaky bug, re-run the loop from step 1 and show 0 failures in N runs.
- Clean up: `rg -n DBGLOOP` must return nothing. Delete scratch scripts and any bisect state.

## Report

```
Symptom:      <exact error / wrong behavior>
Reproduced:   <test or script path>; failed N/N before the fix (or X/50 for flaky)
Root cause:   <file:line>: <what was wrong and why it produced the symptom>
How found:    <the key evidence: bisect commit, log line, experiment>
Fix:          <what changed, files>
Regression:   <test name>; verified it fails without the fix and passes with it
Siblings:     <other places checked or fixed>
Ruled out:    <hypotheses eliminated, one line each>
Residual risk / follow-ups: <anything unexplained>
```
