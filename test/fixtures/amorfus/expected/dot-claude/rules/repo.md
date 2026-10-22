## Deploy
A push of `main` runs CI (`.github/workflows/check.yml`) and deploys nothing; deploys go through `npm run deploy` and `npm run publish:ipfs`, run by the owner with an explicit go-ahead.
## Gate
Run before every commit.
## Conflict stops
Config values, rulings in docs/, golden hashes, schema constants, test expectations, user-facing copy.
## Branch names
`relay-probe-timeout`, `mesher-guard-caps`, `session-branch-workflow`
