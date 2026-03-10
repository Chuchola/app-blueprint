# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A full-stack e-commerce monorepo with a Medusa v2 headless commerce backend and a Next.js 15 storefront. Supports multi-regional shopping (7 EU countries), Google OAuth and email/password auth, Stripe payments, Resend email notifications, and a custom wishlist module.

## Monorepo Structure

```
/
├── server/           # Medusa v2 backend (port 9000)
└── server-storefront/ # Next.js 15 storefront (port 8000)
```

## Commands

### Development
```bash
yarn dev                        # Run both backend and storefront concurrently
yarn dev:server                 # Backend only
yarn dev:storefront             # Storefront only (Turbopack)
```

### Database
```bash
yarn db:setup                   # Initial database setup
yarn db:seed                    # Seed with demo data (regions, products)
yarn migrate                    # Run pending migrations
yarn migrate:rollback           # Rollback last migration
```

### Testing (server only)
```bash
yarn test                                    # HTTP integration tests
yarn test:server:integration:http            # HTTP integration tests
yarn test:server:integration:modules         # Module integration tests
yarn test:server:unit                        # Unit tests
```

### Storefront only
```bash
yarn --cwd server-storefront lint            # ESLint
yarn --cwd server-storefront build           # Production build
ANALYZE=true yarn --cwd server-storefront build  # Bundle analysis
```

### Install all dependencies
```bash
yarn install:all
```

## Architecture

### Backend (`server/src/`)

- **`api/`** — Custom API routes extending Medusa's built-in `/store` and `/admin` APIs. Custom wishlist endpoints live at `/store/customers/me/wishlist`.
- **`modules/`** — Custom Medusa modules. `wishlist/` is a full custom module with models, migrations, and a service. `notification-resend/` is a custom email provider.
- **`workflows/`** — Medusa workflow definitions for complex business logic (multi-step operations).
- **`subscribers/`** — Event subscribers (e.g., sending welcome emails on customer creation).
- **`jobs/`** — Background/scheduled jobs.
- **`links/`** — Medusa data links connecting modules.
- **`scripts/seed.ts`** — Seeds 7 EU regions, sales channels, fulfillment, and demo products.

Backend config: `server/medusa-config.ts`

### Storefront (`server-storefront/src/`)

- **`app/[countryCode]/`** — Country-code-based routing is the primary routing pattern. Two route groups: `(main)` for the main site and `(checkout)` for the checkout flow.
- **`app/[countryCode]/(main)/profile/`** — Protected route using Next.js parallel routes (`@dashboard` and `@login` slots) for auth-aware rendering without redirects.
- **`lib/data/`** — All server-side data fetching (server actions). Each file corresponds to a domain: `cart.ts`, `customer.ts`, `orders.ts`, `products.ts`, `wishlist.ts`, etc.
- **`lib/context/`** — React Context providers.
- **`lib/hooks/`** — Custom React hooks.
- **`modules/`** — Feature-based component directories (not the same as backend modules). Each directory contains components for a feature area (cart, checkout, products, etc.).
- **`middleware.ts`** — Handles country code detection, redirects, and cookie-based JWT auth (`_medusa_jwt`).

Path aliases: `@lib/*` → `src/lib/`, `@modules/*` → `src/modules/`, `@pages/*` → `src/pages/`

### Key Integration Points

- Storefront calls backend at `MEDUSA_BACKEND_URL` (default `http://localhost:9000`) using `@lib/config.ts`.
- Auth uses JWT stored in `_medusa_jwt` cookie; Google OAuth callback is at `/{countryCode}/auth/google/callback`.
- Stripe handles payments; Resend handles transactional email.
- Redis is required at `localhost:6379` for the backend.

## Testing Patterns

Tests are colocated:
- HTTP integration tests: `server/integration-tests/http/`
- Module tests: `server/src/modules/*/__tests__/`
- Unit tests: `server/src/**/__tests__/**/*.unit.spec.[jt]s`

Test type is controlled by `TEST_TYPE` env var (`integration:http`, `integration:modules`, `unit`).
