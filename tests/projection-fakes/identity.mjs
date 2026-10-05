// Stand-in @azure/identity for the projection renewal simulation. A token request for a scope that
// contains FAKE_TOKEN_FAIL is refused, as a missing grant or identity would be.
export class DefaultAzureCredential {
  async getToken(scope) {
    const scopes = Array.isArray(scope) ? scope : [scope];
    const refuse = process.env.FAKE_TOKEN_FAIL;
    if (refuse && scopes.some((s) => s.includes(refuse))) throw new Error(`stand-in credential refused ${scopes.join(' ')}`);
    return { token: `stand-in-${scopes.join(' ')}`, expiresOnTimestamp: Date.now() + 3600 * 1000 };
  }
}
