# App Blueprint

## Development

> **⚠️ Important:** Make sure to activate Corepack before starting development:
> ```bash
> corepack enable
> ```

1. Clone the project
   ```bash
   git clone git@github.com:Chuchola/medusa-store-starter.git some_store
   cd some_store
   ```

2. Install root workspace dependencies
   ```bash
   yarn install
   ```

3. Configure the project — installs dependencies for `server/` and `storefront/`, copies `.env` templates, prompts for database credentials, creates the database, runs migrations, and seeds initial data.
   ```bash
   yarn configure
   ```

4. Copy the publishable API key from the console and paste it into `storefront/.env.local` as `NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY`.

5. Create an admin user
   ```bash
   yarn medusa exec ./src/scripts/create-admin-user.ts <email> <password>
   ```

6. Start the development server
   ```bash
   yarn dev
   ```

## Deploy to Production or Staging

**Prerequisites:**

1. A clean Ubuntu server with root user and password
2. A domain and subdomains: `api.domain`, `admin.domain`
3. A generated SSH key. The public part of this key must be copied to the server to allow passwordless login

**Steps:**
1. Rename env templates in `deploy/prod_envs` (or `deploy/stage_envs`) by removing the `template` prefix and fill in the required parameters: VPS host, domain names, database/Redis passwords, SSH key path, etc.
   - `.env.setup-vps` — VPS connection and infrastructure settings
   - `.env.deploy-server` — Medusa server environment variables (secrets, API keys)
   - `.env.deploy-worker` — Medusa worker environment variables
   - `.env.deploy-storefront` — Next.js storefront environment variables

2. Provision a clean Ubuntu 22.04 VPS — creates a deploy user, installs Node.js + PM2, PostgreSQL, Redis, configures Nginx reverse proxy for API/storefront/admin domains, sets up UFW firewall, and optionally obtains SSL certificates via Certbot.
   ```bash
   ./deploy/setup-vps.sh <prod | stage>
   ```

3. Deploy the Medusa backend — builds the server in Docker for Linux, packages and uploads the artifact to VPS, creates the database if needed, runs migrations, generates PM2 config, and starts `medusa-server` + `medusa-worker` processes.
   ```bash
   ./deploy/deploy-server.sh <prod | stage>
   ```

4. Run the seed script on the remote server — compiles a local TypeScript script, uploads it to VPS, and executes it via `npx medusa exec`. Populates the database with initial data (products, categories, regions, etc.).
   ```bash
   ./deploy/run-script.sh <prod | stage> seed
   ```

5. Create an admin user on the remote server — runs the `create-admin-user` script with the specified credentials.
   ```bash
   ./deploy/run-script.sh <prod | stage> create-admin-user <email> <password>
   ```

6. Deploy the Next.js storefront — verifies Medusa API availability, builds the storefront in Docker (standalone output), packages and uploads the artifact to VPS, generates PM2 config, and starts the `storefront` process on port 8000.
   ```bash
   ./deploy/deploy-storefront.sh <prod | stage>
   ```
