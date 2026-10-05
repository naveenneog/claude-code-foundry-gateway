/**
 * The one line a renewal run prints last, so Azure Monitor can alert on it.
 * infra/projection-renewal.bicep's alert queries match these exact strings;
 * tests/Test-ProjectionRenewal.ps1 checks that they agree.
 */
export const RENEWAL_SUCCEEDED = 'projection-renewal-succeeded';
export const RENEWAL_FAILED = 'projection-renewal-failed';
