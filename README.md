# Flowise — per-client single-tenant VM

Low-code builder for AI agents and chatflows ([github.com/FlowiseAI/Flowise](https://github.com/FlowiseAI/Flowise),
[docs.flowiseai.com](https://docs.flowiseai.com)). One VM = one client. The client gets a
visual drag-and-drop builder; the LLM backend is **avots.ai** via its OpenAI-compatible API,
using the client's **own avots key**.

- Image: `flowiseai/flowise:3.1.2` (Apache-2.0 community build), single container, port 3000.
- DB: SQLite under `/root/.flowise` (named Docker volume — survives restarts/re-bakes).
- Web UI behind **Caddy** with automatic TLS; only **80/443** are public, 3000 is not.

## What the client gets

A private Flowise instance at `https://{domain}`, pre-wired to avots.ai. They log in with the
admin account created at provision time, build chatflows visually, and the avots API key is
already stored as a reusable **ChatOpenAI** credential.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Flowise (pinned, bound to `127.0.0.1:3000`) + Caddy (80/443). Named volume, `.env`, hardening. |
| `Caddyfile` | `{$DOMAIN}` -> `reverse_proxy flowise:3000`, automatic HTTPS. |
| `.env.example` | Template for per-client secrets/config. Copy to `.env`; never commit a real `.env`. |
| `seed-credential.sh` | First-boot: register admin, login, POST the avots key as an `openAIApi` credential. Idempotent. |
| `autoinstall-snippet.yaml` | cloud-init `write_files` (`.env`) + `runcmd` (`compose up` then seed). |

## Run (manual / dev)

```bash
cp .env.example .env
# Fill DOMAIN, AVOTS_API_KEY, ADMIN_*, and generate each secret with: openssl rand -hex 32
docker compose up -d
# Once up, inject the avots key (reads vars from .env):
set -a; . ./.env; set +a; ./seed-credential.sh
```

Then open `https://{domain}` and log in with `ADMIN_EMAIL` / `ADMIN_PASSWORD`.

In production this is automated by `autoinstall-snippet.yaml`: cloud-init writes `.env` with the
injected `{avots_key}`, `{domain}`, generated secrets, runs `docker compose up -d`, then runs
`seed-credential.sh`.

## avots wiring (exact)

avots is reached through Flowise's **ChatOpenAI** node (OpenAI-compatible):

1. **Base Path** — in the ChatOpenAI node, open **Additional Parameters** and set
   **Base Path** (`basePath`) to:
   ```
   https://api.avots.ai/openai/v1
   ```
   This must be set per ChatOpenAI node; it is a node parameter, not a global env var, so the
   seed script cannot set it for you.
2. **Credential** — attach the **ChatOpenAI** credential named **`avots`** (type
   `openAIApi`). This is created automatically by `seed-credential.sh` and holds the avots key
   in its `openAIApiKey` field.
3. **Model** — type a model id served by avots, e.g. `anthropic/claude-opus-4.8` (the lazy
   alias `claude` also works). avots exposes OpenRouter-style ids via `/v1/models`.

### How the key is injected

`seed-credential.sh` (run on first boot):
1. waits for Flowise on `http://127.0.0.1:3000`,
2. registers the admin via `POST /api/v1/account/register` (`{user:{name,email,credential}}`),
3. logs in via `POST /api/v1/account/login` to obtain the JWT auth cookies,
4. creates the credential via `POST /api/v1/credentials` with
   `{name:"avots", credentialName:"openAIApi", plainDataObj:{openAIApiKey:"av_mcp_..."}}`.

The credential endpoint requires an authenticated session (the `credentials:create`
permission), which is why the script logs in first rather than using a plain API key. Because
`FLOWISE_SECRETKEY_OVERWRITE` is fixed per VM, the stored (encrypted) credential stays valid
across container re-creates and re-bakes.

> If a release requires e-mail verification before the admin can log in, step 3 will fail.
> Finish admin setup once in the browser, then re-run `seed-credential.sh` to inject the key.

## Ports / TLS

- `80`, `443` — public, handled by Caddy. Caddy auto-provisions and renews a Let's Encrypt cert
  for `{domain}` (needs DNS pointing at the VM and 80/443 reachable).
- `3000` — Flowise, bound to `127.0.0.1` only (loopback, for the seed script). Never exposed on
  `0.0.0.0`; the only path in is through Caddy.

## Security checklist

- [ ] **Do NOT set `ALLOW_BUILTIN_DEP=true`.** It is left `false` (the safe default). Enabling it
      widens the custom-tool NodeVM sandbox, relevant to CVE-2025-34267 and related escapes.
- [ ] **Set all per-VM secrets** (`FLOWISE_SECRETKEY_OVERWRITE`, `JWT_AUTH_TOKEN_SECRET`,
      `JWT_REFRESH_TOKEN_SECRET`, `TOKEN_HASH_SECRET`, `EXPRESS_SESSION_SECRET`) to unique
      `openssl rand -hex 32` values. Defaults let an attacker forge tokens.
- [ ] **Mark chatflows non-public.** Individual chatflows are PUBLIC by default — assign a
      chatflow-level API key to every chatflow you don't intend to expose anonymously.
- [ ] **Keep the builder UI behind auth + Caddy.** Do not publish port 3000; rely on Flowise's
      account auth plus TLS. Consider extra IP allowlisting at Caddy for the builder if the
      client only needs the public prediction endpoints exposed.
- [ ] **Rotate the admin password** after first login if the provisioned one was templated.
- [ ] Hardening already applied in compose: `no-new-privileges`, no `docker.sock` mount,
      `SECURE_COOKIES=true`, `EXPIRE_AUTH_TOKENS_ON_RESTART=true`, telemetry disabled.

## License note

This is the **Apache-2.0 community** build only. Do **not** enable or ship anything from the
`enterprise/` directory (the `enterprise/` SSO/license features are separately licensed). Leave
`LICENSE_URL` / `FLOWISE_EE_LICENSE_KEY` unset.

## Version pin

Pinned to `flowiseai/flowise:3.1.2` (latest stable as of 2026-06-05; `:latest` == `3.1.2`,
pushed 2026-04-14). Re-verify the tag at
<https://hub.docker.com/r/flowiseai/flowise/tags> before each bake; Flowise ships CVEs and
releases frequently, so keep a patch + re-bake pipeline.

## Caveats / verify before baking

- **Auth API paths** (`/api/v1/account/register`, `/api/v1/account/login`) are derived from the
  v3 source/route mounts and a security advisory, not from a stable published API reference.
  Smoke-test `seed-credential.sh` against a real `3.1.2` container and adjust if a path/body
  field differs (e.g. the register body may need additional `organization`/`workspace` fields,
  and login may set cookies under different names).
- **E-mail verification:** post-advisory builds may gate login behind verification (see above).
  Confirm whether a single-tenant first-boot register can log in immediately on `3.1.2`.
- **`POST /api/v1/credentials` body** (`name` / `credentialName` / `plainDataObj`) is taken from
  the credentials controller/service, which forward the whole body to `transformToCredentialEntity`.
  Verify the exact field names hold on `3.1.2`.
