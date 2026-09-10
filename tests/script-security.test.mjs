import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const source = name => readFileSync(new URL(`../scripts/${name}`, import.meta.url), 'utf8');

test('interactive workstation configuration retrieves trusted metadata and rejects unsafe settings', () => {
  const resolver = source('setup-claude-workstation.sh').match(/^resolve_gateway_interactive_\(\) \{[\s\S]*?^\}/m)?.[0];
  assert.ok(resolver, 'Missing interactive gateway configuration resolver');
  const tenant = '11111111-1111-1111-1111-111111111111';
  const config = { clientId: '22222222-2222-2222-2222-222222222222', sessionLifetimeSec: 3600, redirectPort: 8400, additionalRedirectReferrerHosts: 'login.microsoftonline.com' };
  const metadata = { issuer: `https://login.microsoftonline.com/${tenant}/v2.0`, authorization_endpoint: `https://login.microsoftonline.com/${tenant}/oauth2/v2.0/authorize`, token_endpoint: `https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token` };
  const run = (value, discovery = metadata) => spawnSync('bash', ['-c', `${resolver}\ncurl() { [[ "$*" == "--proto =https --max-time 30 -fsS https://login.microsoftonline.com/$INPUT_TENANT/v2.0/.well-known/openid-configuration" ]] || return 2; printf '%s' "$MOCK_METADATA"; }\nresolve_gateway_interactive_ "$INPUT_CONFIG" "$INPUT_TENANT"`], {
    encoding: 'utf8', timeout: 5000,
    env: { ...process.env, INPUT_CONFIG: JSON.stringify(value), INPUT_TENANT: tenant, MOCK_METADATA: JSON.stringify(discovery) }
  });
  const result = run(config);
  assert.equal(result.status, 0, result.stderr);
  const profile = JSON.parse(result.stdout);
  assert.equal(profile.inferenceCredentialKind, 'interactive');
  assert.equal(profile.inferenceGatewayOidcAuthFlow, 'browser');
  assert.equal(profile.inferenceSessionLifetimeSec, 3600);
  assert.deepEqual(profile.inferenceGatewayOidc, {
    clientId: config.clientId, issuer: metadata.issuer, authorizationUrl: metadata.authorization_endpoint,
    tokenUrl: metadata.token_endpoint, bearerTokenType: 'access_token', scopes: 'openid profile https://cognitiveservices.azure.com/.default',
    redirectPort: 8400, additionalRedirectReferrerHosts: 'login.microsoftonline.com'
  });
  assert.ok(!('inferenceCredentialHelper' in profile));
  for (const change of [
    { clientId: 'bad' }, { clientSecret: 'must-not-be-accepted' }, { sessionLifetimeSec: 0 },
    { redirectPort: 70000 }, { redirectPort: '8400' }, { bearerTokenType: 'id_token' },
    { scopes: 'openid profile' }, { authFlow: 'bad' }, { additionalRedirectReferrerHosts: '*.example.org' },
    { issuer: 'https://evil.example' }, { additionalRedirectReferrerHosts: 'https://evil.example/path' }
  ]) assert.notEqual(run({ ...config, ...change }).status, 0, JSON.stringify(change));
  assert.notEqual(run(config, { ...metadata, token_endpoint: 'https://evil.example/token' }).status, 0);
  assert.equal(run({ clientId: config.clientId, authFlow: 'broker' }).status, 0);
  const minimal = JSON.parse(run({ clientId: config.clientId }).stdout);
  assert.ok(!('inferenceSessionLifetimeSec' in minimal));
  assert.ok(!('redirectPort' in minimal.inferenceGatewayOidc));
  const filter = source('setup-claude-workstation.sh').match(/--argjson cowork "\$cowork_val" '([\s\S]*?)' > "\$PROFILE"/)?.[1];
  assert.ok(filter, 'Desktop profile writer not found');
  for (const interactive of [{}, profile]) {
    const rendered = spawnSync('jq', ['-n', '--arg', 'url', 'https://gateway.example/claude', '--arg', 'helper', '/synthetic/helper.sh',
      '--argjson', 'interactive', JSON.stringify(interactive), '--argjson', 'models', '[{"name":"test-model"}]', '--argjson', 'cowork', 'false', filter], { encoding: 'utf8' });
    assert.equal(rendered.status, 0, rendered.stderr);
    const output = JSON.parse(rendered.stdout);
    assert.equal(output.inferenceGatewayBaseUrl, 'https://gateway.example/claude');
    assert.equal(output.coworkTabEnabled, false);
    if (interactive === profile) {
      assert.equal(output.inferenceCredentialKind, 'interactive');
      assert.equal(Object.keys(output).filter(key => key.startsWith('inferenceCredentialHelper')).length, 0);
      assert.deepEqual(output.inferenceGatewayOidc, profile.inferenceGatewayOidc);
    } else {
      assert.equal(output.inferenceCredentialKind, 'helper-script');
      assert.equal(output.inferenceCredentialHelper, '/synthetic/helper.sh');
      assert.ok(!('inferenceGatewayOidc' in output));
    }
  }
});

test('workstation rejects missing option values without reaching setup', () => {
  for (const option of ['--config', '--gateway-url', '--tenant-id']) {
    const result = spawnSync('bash', ['scripts/setup-claude-workstation.sh', option], { encoding: 'utf8', timeout: 1000 });
    assert.equal(result.status, 2, `${option}: ${result.error?.message || result.stderr.slice(0, 200)}`);
  }
});

test('workstation dry run is offline and validates explicit credential destinations', () => {
  for (const url of ['http://example.org', 'https://user:password@example.org', 'https://example.org/#fragment']) {
    const result = spawnSync('bash', ['scripts/setup-claude-workstation.sh', '--dry-run', '--gateway-url', url], { encoding: 'utf8', timeout: 1000 });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /HTTPS/);
  }
  const result = spawnSync('bash', ['scripts/setup-claude-workstation.sh', '--dry-run', '--gateway-url', 'https://example.org/claude'], { encoding: 'utf8', timeout: 1000 });
  assert.equal(result.status, 0);
  assert.match(result.stdout, /[Dd]ry.run/);
});

test('existing setup and harness forbid risky execution paths', () => {
  assert.doesNotMatch(source('setup-claude-workstation.sh'), /curl[^\n]+\| sudo bash/);
  assert.match(source('setup-claude-workstation.sh'), /Invalid appliedId/);
  assert.match(source('Setup-ClaudeWorkstation.ps1'), /Invalid appliedId/);
  assert.match(source('Setup-ClaudeWorkstation.ps1'), /MaximumRedirection 0/);
  assert.match(source('test-setup-workstation.sh'), /uname\(\)/);
});

test('PowerShell output generation and identity transport have boundary checks', () => {
  assert.match(source('New-OnboardingEmail.ps1'), /Invalid recipient/);
  assert.match(source('New-OnboardingEmail.ps1'), /Replace\("'", "''"\)/);
  assert.match(source('New-ClaudeCodePolicy.ps1'), /SecurityElement\]::Escape/);
  assert.match(source('Sync-ClaudeAccess.ps1'), /Refusing untrusted Graph/);
  assert.match(source('Sync-ClaudeAccess.ps1'), /Named value write failed/);
});

test('audit and deletion failures cannot appear as clean results', () => {
  assert.match(source('Find-ClaudeUserData.ps1'), /Compliance query failed/);
  assert.match(source('Remove-ClaudeUserData.ps1'), /Refusing untrusted purge/);
  assert.match(source('Remove-ClaudeUserData.ps1'), /Purge submission failed/);
  assert.match(source('Get-ClaudeBypass.ps1'), /Cannot read role definition/);
});

test('live credentials and governance mutations are guarded', () => {
  assert.doesNotMatch(source('get-foundry-token.sh'), /token="\$\(az[^\n]+\|\| true/);
  assert.doesNotMatch(source('setup-claude-workstation.sh'), /token="\$\(az[^\n]+\|\| true/);
  assert.match(source('Setup-ClaudeWorkstation.ps1'), /-Body \$body -MaximumRedirection 0/);
  assert.match(source('Import-ClaudeEntitlement.ps1'), /Refusing untrusted Graph/);
  assert.match(source('Debug-ClaudeCode.ps1'), /if \(\$token -and -not \$SkipLiveCall\)/);
  assert.match(source('Show-Governance.ps1'), /finally/);
  assert.match(source('Show-Governance.ps1'), /\$Execute -and -not \$SkipThrottleTest/);
  assert.match(source('Test-FoundryDirect.ps1'), /Invalid Foundry resource name/);
});

test('token helper discards output from failed az commands during refresh', () => {
  const result = spawnSync('bash', ['-c', 'az() { printf eyJnot-a-token; return 1; }; export -f az; export CLAUDE_HELPER_CONTEXT=refresh; exec bash scripts/get-foundry-token.sh'], { encoding: 'utf8', timeout: 3000 });
  assert.equal(result.status, 2);
  assert.equal(result.stdout, '');
});

test('authenticated requests reject redirects and partial results without exposing bodies', async () => {
  const { request, ARM } = await import('../scripts/lib/common.mjs');
  let issued = false;
  await assert.rejects(request('https://example.org/private', ARM, { token: () => { issued = true; return 'synthetic'; } }), /trusted origin/);
  assert.equal(issued, false);
  const options = { token: () => 'synthetic', fetch: async (url, init) => {
    assert.equal(init.redirect, 'error');
    return new Response('secret-body', { status: 403 });
  } };
  await assert.rejects(request(`${ARM}/test`, ARM, options), error => /HTTP 403/.test(error.message) && !error.message.includes('secret-body'));
  await assert.rejects(request(`${ARM}/test`, ARM, { ...options, fetch: async () => new Response('{"error":{"code":"PartialError"}}') }), /partial or failed/);
});

test('capture is offline and policy replacement is validated and conditional', () => {
  assert.doesNotMatch(source('Capture-Transcripts.ps1'), /cmd \/c|Save-InteractiveTranscript|'-SkipInstall'/);
  assert.match(source('Capture-Transcripts.ps1'), /Get-Help/);
  assert.match(source('Set-GatewayPolicy.ps1'), /<!DOCTYPE\|<!ENTITY/);
  assert.match(source('Set-GatewayPolicy.ps1'), /If-Match/);
  assert.match(source('Find-ClaudeUserData.ps1'), /Refusing untrusted table pagination/);
  assert.match(source('Find-ClaudeUserData.ps1'), /Ambiguous subject/);
});

test('output writer refuses dangling links and preserves private file permissions', async () => {
  const { mkdtempSync, rmSync, symlinkSync, writeFileSync, statSync, existsSync } = await import('node:fs');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  const { write } = await import('../scripts/lib/common.mjs');
  const root = mkdtempSync(join(tmpdir(), 'private-output-'));
  try {
    const target = join(root, 'missing');
    const link = join(root, 'link');
    symlinkSync(target, link);
    assert.throws(() => write(link, 'private'));
    assert.equal(existsSync(target), false);
    const output = join(root, 'output');
    writeFileSync(output, 'old', { mode: 0o644 });
    write(output, 'private');
    assert.equal(statSync(output).mode & 0o777, 0o600);
  } finally { rmSync(root, { recursive: true, force: true }); }
});