FROM node:22-bookworm-slim

WORKDIR /app/sync
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src

ENTRYPOINT ["node", "/app/sync/src/apply-projection.mjs"]
CMD ["--graph", "--standard", "claude-code-standard", "--premium", "claude-code-premium"]
