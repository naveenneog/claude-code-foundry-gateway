# Build context: the sync package that scripts/ClaudeProjectionPackage.ps1 writes, which holds
# sync/ and resolver/src/entitlement.mjs at their repository paths (ADR-0049):
#   az acr build --registry <acr> --image claude-projection-sync:<tag> --file sync/Dockerfile --no-logs <package-directory>
FROM node:22-bookworm-slim

WORKDIR /app/sync
COPY sync/package.json sync/package-lock.json ./
RUN npm ci --omit=dev --no-audit --fund=false
COPY sync/src ./src
COPY resolver/src/entitlement.mjs /app/resolver/src/entitlement.mjs

ENTRYPOINT ["node", "/app/sync/src/apply-projection.mjs"]
CMD ["--graph", "--standard", "claude-code-standard", "--premium", "claude-code-premium"]
