import { fileURLToPath, pathToFileURL } from 'node:url';

export async function resolve(specifier, context, nextResolve) {
  if (specifier === '@azure/cosmos') {
    return { shortCircuit: true, url: pathToFileURL(fileURLToPath(new URL('./fake-cosmos.mjs', import.meta.url))).href };
  }
  if (specifier === '@azure/identity') {
    return { shortCircuit: true, url: pathToFileURL(fileURLToPath(new URL('./fake-identity.mjs', import.meta.url))).href };
  }
  return nextResolve(specifier, context);
}
