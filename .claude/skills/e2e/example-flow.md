---
name: example-homepage
app: web
port: 3000
requires-auth: false
triggers:
  - "src/routes/**"
  - "src/components/**"
  - "src/lib/**"
  - "src/styles.css"
  - "vite.config.ts"
  - "tsconfig.json"
  - "package.json"
  - "package-lock.json"
  - "Dockerfile"
  - "docker-compose.yml"
---
# Example homepage flow (REPLACE ME)

This file is a template shipped by the dev kit. Copy it to your project's flow directory and adapt:

- **Monorepo-with-shared layout**: `apps/shared/test/e2e/<your-flow>.md`
- **Flat layout**: `test/e2e/<your-flow>.md`

Delete this note, update the frontmatter (`name`, `app`, `port`, `requires-auth`, `triggers`), and write the step-by-step flow below.

## Preconditions
- Dev server running on the declared port (see `.claude/rules/dev-server.md`)

## Steps
1. `agent-browser --headed open http://localhost:<port>`
2. `agent-browser set viewport 1920 1080`
3. `agent-browser wait --load networkidle`
4. `agent-browser snapshot -i`
5. Confirm the content you care about is visible

## Failure indicators
- Blank page
- Console errors in devtools
- Missing expected content
- agent-browser can't find elements you expected
