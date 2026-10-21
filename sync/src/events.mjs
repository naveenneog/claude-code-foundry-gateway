/**
 * The one line a renewal run prints last, so Azure Monitor can alert on it.
 * infra/projection-renewal.bicep's alert queries match these exact strings;
 * tests/Test-ProjectionRenewal.ps1 checks that they agree.
 */
export const RENEWAL_SUCCEEDED = 'projection-renewal-succeeded';
export const RENEWAL_FAILED = 'projection-renewal-failed';

/**
 * Lines a successful full renewal prints before its summary: the business unit of every member, which
 * analytics/chargeback-cost.kql reads from ContainerAppConsoleLogs (ADR-0066).
 */
export const MEMBERSHIP_EVENT = 'projection-membership';
