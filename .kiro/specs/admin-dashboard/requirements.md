# Requirements Document

## Introduction

An authenticated admin dashboard at `admin.awssecurityecuador.com` for event
organizers to view, search, and analyze event registrations and check-in status
stored in DynamoDB, and to export attendee lists with consent-aware filters
(notably the recruiter/job-pool consent). The dashboard reuses the project's
serverless pattern (CloudFront + S3 static frontend, API Gateway HTTP API,
Lambda, DynamoDB) and adds Amazon Cognito for authentication.

This replaces the current shared-secret model used by the check-in page with
proper user-based authentication and role separation, and provides a
LOPDP-compliant way to share a candidate pool with sponsors/recruiters.

## Glossary

- **Admin**: event organizer with full access (view all data, export all, manage check-in).
- **Recruiter**: a sponsor/recruiter user with restricted access (only the
  consented candidate pool).
- **Candidate pool**: the subset of registrations where `consent_recruiters = true`.
- **Registration**: a real attendee record in DynamoDB (excludes `EMAIL_LOCK#` items).

## Requirements

### Requirement 1: Authentication via Cognito

**User Story:** As an organizer, I want to log in securely with my own
credentials, so that only authorized people can access attendee data.

#### Acceptance Criteria
1. WHEN an unauthenticated user opens the dashboard THEN the system SHALL redirect to the Cognito Hosted UI login.
2. WHEN a user authenticates successfully THEN the system SHALL grant access using a Cognito-issued JWT.
3. WHEN an API request arrives without a valid Cognito JWT THEN the API SHALL respond 401 Unauthorized.
4. WHEN a user's token expires THEN the system SHALL require re-authentication before further API calls succeed.
5. IF multi-factor authentication is enabled for a user THEN the system SHALL enforce it at login.
6. The system SHALL NOT allow self-registration; admin accounts SHALL be provisioned manually.

### Requirement 2: Role-based access

**User Story:** As an organizer, I want different access levels, so that sponsors
only see the consented candidate pool and not the full attendee list.

#### Acceptance Criteria
1. WHEN a user in the `admins` group calls the API THEN the system SHALL return all registration data.
2. WHEN a user in the `recruiters` group calls the API THEN the system SHALL return ONLY registrations where `consent_recruiters = true`.
3. WHEN a recruiter attempts to access an admin-only endpoint THEN the API SHALL respond 403 Forbidden.
4. The system SHALL determine role from the Cognito group claim in the JWT, not from client input.

### Requirement 3: View registrations

**User Story:** As an admin, I want to see the list of registered people, so that
I can monitor sign-ups.

#### Acceptance Criteria
1. WHEN an admin opens the dashboard THEN the system SHALL display the list of registrations for the event.
2. The system SHALL exclude internal `EMAIL_LOCK#` items from all displayed lists and counts.
3. WHEN displaying a registration THEN the system SHALL show name, email, city, AWS experience, AI experience, employment status, and check-in status.
4. WHEN the list exceeds one page THEN the system SHALL paginate results.
5. WHEN an admin enters a search term THEN the system SHALL filter the list by name or email.

### Requirement 4: Metrics

**User Story:** As an admin, I want summary metrics, so that I can understand
attendance at a glance.

#### Acceptance Criteria
1. WHEN an admin opens the dashboard THEN the system SHALL display total registrations, checked-in count, and remaining capacity (out of 400).
2. The system SHALL display a breakdown by city and by experience level.
3. The system SHALL display the count of registrations that opted into the recruiter pool.
4. All metrics SHALL exclude `EMAIL_LOCK#` items.

### Requirement 5: Export with consent-aware filters

**User Story:** As an admin, I want to export attendee data as CSV with filters,
so that I can share an LOPDP-compliant candidate pool with sponsors.

#### Acceptance Criteria
1. WHEN an admin requests an export THEN the system SHALL produce a CSV of the selected records.
2. WHEN exporting the recruiter/candidate pool THEN the system SHALL include ONLY records where `consent_recruiters = true`.
3. The system SHALL support filtering exports by employment status and city.
4. WHEN a recruiter requests an export THEN the system SHALL only ever return consented records, regardless of requested filters.
5. WHEN any export is generated THEN the system SHALL log who exported, when, the filter used, and the record count, for LOPDP traceability.
6. The recruiter pool export SHALL exclude fields not covered by the recruiter consent.

### Requirement 6: Check-in management (optional consolidation)

**User Story:** As staff, I want to perform check-in from the authenticated
dashboard, so that we no longer rely on a shared secret.

#### Acceptance Criteria
1. WHEN an authenticated admin/staff submits a registration code THEN the system SHALL mark the attendee as checked-in.
2. WHEN a code is already checked-in THEN the system SHALL indicate it was previously checked-in with the timestamp.
3. WHEN an invalid code is submitted THEN the system SHALL return a not-found result.

### Requirement 7: Infrastructure & hosting

**User Story:** As the maintainer, I want the dashboard to follow the existing
serverless/IaC pattern, so that it is consistent and reproducible.

#### Acceptance Criteria
1. The dashboard frontend SHALL be a static site in a private S3 bucket served via CloudFront with OAC.
2. The CloudFront distribution SHALL enforce the `block-dotfiles` function and security headers policy, consistent with other sites.
3. The API SHALL be an API Gateway HTTP API integrated with a Lambda function, defined in Terraform.
4. All resources SHALL be defined in Terraform and deployed via the existing GitHub Actions workflow.
5. The dashboard SHALL be reachable at `admin.awssecurityecuador.com` with an ACM certificate and Route53 records.
6. The dashboard CloudFront distribution SHALL geo-restrict access to Ecuador only (`EC`), since it is an internal organizer tool.
7. The dashboard SHALL NOT use a `custom_error_response` mapping 403 to 200, so the geo-restriction is enforced (consistent with the project gotcha).

### Requirement 8: Security & data protection

**User Story:** As a data controller, I want the dashboard to protect attendee
data, so that we comply with LOPDP and minimize exposure.

#### Acceptance Criteria
1. The DynamoDB read access SHALL be scoped to the admin Lambda's IAM role only.
2. The API SHALL never expose `EMAIL_LOCK#` items or internal attributes to clients.
3. WHEN returning data to recruiters THEN the system SHALL apply field-level minimization (only consented fields).
4. The system SHALL transmit all data over HTTPS only.
5. Sensitive operations (export) SHALL require the `admins` role except for the consented-pool export available to `recruiters`.
