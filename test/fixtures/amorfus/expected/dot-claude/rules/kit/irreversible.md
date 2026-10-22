<!-- kit: rendered from slices/core/rules/irreversible.md — edit the source in the kit, never this copy -->
# Irreversible actions

**Allow without prompting** if all of these are true:
1. The action is local (no network calls, no external services)
2. The action is reversible (can be undone with git checkout or re-run)
3. The action does not spend funds or expose secrets

**Always confirm with the user** if any of these are true:
1. The action sends a transaction or deploys to a network
2. The action publishes code or data to an external service
3. The action uses a private key or API key
4. The action cannot be undone
