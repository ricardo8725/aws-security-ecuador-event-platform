# Product Overview

AWS User Group Security Ecuador — community website and event platform for the AWS Security user group in Ecuador.

## Purpose

Provide an online presence for the community: showcase upcoming/past events, allow event registration with QR-based check-in, and host sub-sites for specific events (AI Security Day, sponsors page).

## Key Features

- Main community landing page (events, about, community leaders)
- Event registration system with email confirmation and QR codes
- QR-based check-in system for in-person events
- Dedicated sub-sites: AI Security Day (`aisecurity/`), registration portal (`register/`), sponsors (`sponsors/`)
- LOPDP (Ecuador data protection law) compliance for attendee data

## Domain

- Primary: awssecurityecuador.com
- Sub-sites served via separate S3 buckets + CloudFront distributions

## Featured Event

- **AWS GenAI Security Day** — 18 Julio 2026, 08:00–16:00 ECT
- Venue: Universidad Ecotec — Av. Juan Tanca Marengo Km. 2, Guayaquil, Ecuador
- Capacity: 400 registrations max
- Registration URL: https://register.awssecurityecuador.com
- Event microsite: https://aisecurity.awssecurityecuador.com

## Featured Communities (aisecurity site)

- AWS UG Security Ecuador (host)
- AWS User Group Quito

## Language

- UI content is in Spanish (Ecuador)
- Code comments and variable names are in English
- API error messages returned to users are in Spanish

## Email Addresses

- `noreply@awssecurityecuador.com` — transactional sends via SES (production access enabled)
- `privacy@awssecurityecuador.com` — LOPDP requests
- `info@awssecurityecuador.com` — general contact
- `sponsors@awssecurityecuador.com` — sponsor inquiries (configured as `NOTIFY_EMAIL`)
- All inbound mail uses iCloud Custom Domain catch-all (single mailbox receives `*@awssecurityecuador.com`)
