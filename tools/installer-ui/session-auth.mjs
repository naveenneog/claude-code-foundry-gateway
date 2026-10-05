import { randomBytes } from 'node:crypto';
import { constantTimeTokenEquals, tokenHash } from './http-helpers.mjs';

export function createSessionAuth() {
  let digest = null;
  return {
    issueSecret() {
      const secret = randomBytes(32).toString('base64url');
      digest = tokenHash(secret);
      return secret;
    },
    accepts(cookieValue) {
      return Boolean(digest) && constantTimeTokenEquals(String(cookieValue || ''), digest);
    },
  };
}
