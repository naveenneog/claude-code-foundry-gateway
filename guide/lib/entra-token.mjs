import path from 'node:path';
import { az, ps } from './turnstile-live.mjs';

export function entraToken(scope, { renew = false, runAz = az, runPs = ps } = {}) {
  if (!renew) return runAz(['account', 'get-access-token', '--scope', scope, '--query', 'accessToken', '-o', 'tsv']);
  return runPs(`$python=Join-Path (Split-Path (Split-Path (Get-Command az).Source)) 'python.exe';
    if (!(Test-Path $python)) { throw 'Azure CLI Python is required for Windows broker renewal' };
    & $python $env:P53_RENEW_SCRIPT`, {
    P53_RENEW_SCOPE: scope, P53_RENEW_SCRIPT: path.resolve('guide/renew-entra-token.py'),
  });
}
