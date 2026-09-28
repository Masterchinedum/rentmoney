---
name: codebase-map
description: Onboards to an unfamiliar repository and writes a concise, verified CODEBASE_MAP.md. Finds the entry points, the build, run and test commands, the module boundaries and layering, one real request traced end to end, data stores and external services, hot spots, and a "where does X live" index for common tasks. Every path is checked to exist. Use when the user says "map this codebase", "onboard me", "how is this repo organized", "where does X live", "explain this project's architecture", or on first contact with a new repo.
---

# Codebase map

The goal is a map a new engineer (or a future Claude session) can use to make a correct change on day one. It is not an encyclopedia. Aim for 80 to 150 lines. Every claim is either verified (you saw it or ran it) or marked `(inferred)`.

Read-only: do not modify anything except the map file. Do not install dependencies or start services without asking. Those can have side effects: postinstall scripts, migrations on startup.

## 1. Survey (5 minutes, not 50)

```bash
git ls-files | wc -l
git ls-files | awk -F/ '{print $1}' | sort | uniq -c | sort -rn | head -25        # top-level weight
git ls-files | sed -n 's/.*\.\([A-Za-z0-9]*\)$/\1/p' | sort | uniq -c | sort -rn | head -12   # language mix
git log --format='%ad' --date=short | sed -n '1p;$p'                               # newest / oldest commit
```

Read, in this order and quickly:
1. `README*`, `CONTRIBUTING*`, `docs/` index, `ARCHITECTURE.md`, ADRs (`docs/adr`, `docs/decisions`).
2. Existing `CLAUDE.md` / `AGENTS.md` / `.cursorrules`. Do not duplicate them. Link them.
3. The manifests: `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`/`build.gradle*`, `composer.json`, `*.csproj`.

**Monorepo?** Look for `pnpm-workspace.yaml`, `workspaces` in package.json, `turbo.json`, `nx.json`, `lerna.json`, `go.work`, `[workspace]` in Cargo.toml, a uv workspace in pyproject, or Bazel `BUILD`/`MODULE.bazel` files. If it is one, map the packages first (name, path, purpose, and which packages depend on which), then go deep only on the ones the user cares about. Ask which.

## 2. Build, run, test

The commands CI runs are the most trustworthy. Read `.github/workflows/*.yml` (or GitLab/Circle) before the README, which is often stale.

```bash
jq -r '.scripts // {} | to_entries[] | "\(.key)\t\(.value)"' package.json 2>/dev/null
grep -E '^[A-Za-z0-9_.-]+:([^=]|$)' Makefile 2>/dev/null | cut -d: -f1
just --list 2>/dev/null; task --list 2>/dev/null
ls Procfile* docker-compose*.y*ml compose*.y*ml Dockerfile* .devcontainer 2>/dev/null
cat .env.example .env.sample 2>/dev/null | grep -v '^#' | cut -d= -f1          # required env vars (names only)
cat .tool-versions .nvmrc .node-version .python-version rust-toolchain* 2>/dev/null # pinned runtimes
```

Capture: install, run locally (and which services it needs: DB, Redis, queues), test (all, **one file, one test**), lint, typecheck, build, migrate, seed. Run the cheap, side-effect-free ones (`--help`, lint, a single fast test file) to verify them. Mark each command `verified` or `from CI` or `from README (unverified)`.

## 3. Entry points

Search for where execution starts. Adapt the patterns to the stack:

```bash
rg -l --glob '!**/node_modules/**' 'func main\(\)'                                  # Go (see cmd/*)
rg -n 'if __name__ == .__main__.|^\[project\.scripts\]|FastAPI\(|Flask\(__name__\)|get_wsgi_application|Celery\(' # Python
rg -n '\.listen\(|createServer\(|new Hono\(|express\(\)|NestFactory\.create|"bin":|"main":|"exports":' --glob '!**/node_modules/**'
rg -n 'fn main\(\)|#\[tokio::main\]' --type rust
ls app/ pages/ src/app/ src/pages/ config/routes.rb cmd/ bin/ 2>/dev/null           # framework conventions
rg -n 'schedule|cron|@periodic_task|sidekiq|bullmq|new Worker\(|consumer' -i -l | head -20   # background entry points
```

List every kind of entry point: HTTP server(s), CLI(s), workers and consumers, cron or scheduled jobs, serverless handlers (`serverless.yml`, `template.yaml`, `vercel.json`), migrations, and scripts people actually run.

## 4. Module boundaries

```bash
tree -d -L 3 -I 'node_modules|.git|dist|build|target|vendor|__pycache__|.venv|coverage' 2>/dev/null \
  || find . -maxdepth 3 -type d -not -path '*/node_modules*' -not -path '*/.git*' -not -path '*/.venv*' | sort
```

Then work out the layering from the imports, not from folder names:
- JS/TS: `npx madge --extensions ts,tsx --circular src` and `npx madge --extensions ts,tsx --summary src`, if you may run npx. Otherwise sample imports per top-level folder with `rg -o "from '[^']+'" src/<dir> | sort | uniq -c | sort -rn | head`.
- Go: `go list -f '{{.ImportPath}} -> {{join .Imports " "}}' ./... | grep "$(go list -m)"`.
- Python: `rg -o '^from (\S+) import|^import (\S+)' -r '$1$2' pkg/<dir> | sort | uniq -c | sort -rn | head`.

Identify:
- the layers (for example routes to services to repositories to models) and **where business logic is supposed to live**;
- shared or `utils` dumping grounds;
- **generated code**: protobuf, OpenAPI clients, ORM clients, GraphQL codegen. Note the generator command and "do not edit by hand";
- vendored code;
- circular dependencies, and the layering violations you actually see.

## 5. Trace one real flow end to end

Pick the product's most important action (checkout, sign-up, ingest a file) and follow it with file:line references:

entry (route/handler) → middleware (auth, validation, tenancy) → business logic → persistence (which tables) → side effects (queues, emails, external APIs) → response.

Note where transactions begin, where auth is enforced, where errors are translated to responses, and what is async.

Find the data stores and external services quickly:

```bash
rg -l -i 'psycopg|sqlalchemy|prisma|typeorm|sequelize|knex|gorm|sqlx|pgx|activerecord|mongoose|redis|ioredis|kafka|sqs|rabbit|nats|pubsub' | head -30
rg -o -i "(stripe|twilio|sendgrid|postmark|aws-sdk|@aws-sdk/[a-z-]+|boto3|openai|anthropic|segment|sentry|datadog)" -h | sort | uniq -c | sort -rn
```

Schema lives in: migrations dir, `schema.prisma`, `models.py`, `db/schema.rb`, or `*.sql`.

## 6. Hot spots and hazards

```bash
git log --since='6 months ago' --format= --name-only | grep -v '^$' | sort | uniq -c | sort -rn | head -15   # churn
git ls-files -z '*.py' '*.ts' '*.tsx' '*.go' '*.rb' '*.java' '*.rs' | xargs -0 wc -l 2>/dev/null | grep -v ' total$' | sort -rn | head -10  # biggest files
cat CODEOWNERS .github/CODEOWNERS 2>/dev/null | head -30
```

High churn combined with a large file is where bugs and merge conflicts live. Also note: flaky or slow test areas (from CI config or skip markers), feature-flag systems, and anything surprising ("config is loaded from S3 at boot", "two ORMs in use").

## 7. Write CODEBASE_MAP.md

Save it at the repo root, unless the user names a location. If the file exists, update it in place and preserve any human-written sections. Verify every path first: `for p in <paths>; do test -e "$p" || echo "MISSING $p"; done`.

```markdown
# Codebase map: <project>
_Last verified: <date> at <short sha>. Claims marked (inferred) were not confirmed._

## What this is
<2-3 sentences: what the system does, main tech, deploy target.>

## Run it
| Task | Command | Status |
|---|---|---|
| Install | `pnpm install` | verified |
| Dev server | `pnpm dev` (needs Postgres: `docker compose up -d db`) | from README |
| All tests / one test | `pnpm test` / `pnpm vitest run src/x.test.ts -t "name"` | verified |
Required env: `DATABASE_URL`, `STRIPE_KEY` (see `.env.example`).

## Entry points
- `src/server.ts`: HTTP API (Fastify), routes registered in `src/routes/index.ts`
- `src/worker.ts`: BullMQ consumers for `emails`, `exports`

## Layout and layering
<tree of top dirs with one-line purpose each; the intended dependency direction; known violations>

## Request flow: <action>
1. `src/routes/orders.ts:42`: validates body (zod), requires `auth()`
2. ...

## Data and external services
<stores, schema location, migrations command, external APIs and where they are wrapped>

## Where does X live
| To... | Look at |
|---|---|
| add an API endpoint | `src/routes/*`, copy `orders.ts` |
| add a DB column | `prisma/schema.prisma` then `pnpm prisma migrate dev` |
| change auth / permissions | `src/auth/` |
| add config / env var | `src/config.ts` (+ `.env.example`) |
| add a background job | `src/jobs/`, register in `src/worker.ts` |
<15-30 rows covering the tasks people actually do>

## Hazards
- <generated code, hot spots, gotchas, flaky areas>
```

## Stop and ask when

- The repo is a monorepo with more than about 5 apps and the user has not said which one matters.
- Running anything requires secrets, cloud access, or starting services with side effects.
- Docs and code disagree about something important. Report both. Do not pick silently.

## Report

1. The path of CODEBASE_MAP.md, and its size in lines.
2. A 5-line summary: what the system is, how to run it, the main entry points, the core flow, the biggest hazard.
3. Unverified or inferred claims, and open questions for the team.
