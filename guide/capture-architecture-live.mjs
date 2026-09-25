#!/usr/bin/env node
// Kept as a safe migration notice for older runbooks. It imports no browser code.
console.error('Use the lead-operated portal batch with guide/captures/architecture.json.');
console.error('Do not retry an expired portal session or launch the original profile from this packet.');
console.error('After the owner signs in, the lead runs the shared guide/capture-portal.mjs runner.');
process.exitCode = 2;
