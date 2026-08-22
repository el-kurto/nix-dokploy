# nix-dokploy

[![Build](https://github.com/el-kurto/nix-dokploy/actions/workflows/build.yml/badge.svg)](https://github.com/el-kurto/nix-dokploy/actions/workflows/build.yml)

A NixOS module that runs [Dokploy](https://dokploy.com/) using declarative systemd units.

NixOS-only — uses `systemd.services` and `systemd.tmpfiles` directly.

## Features

- `dokploy-stack.service` and `dokploy-traefik.service` systemd units
- Service ordering: `docker.service` → `dokploy-stack.service` → `dokploy-traefik.service`
- State directory creation via `systemd.tmpfiles`
- Clean stop/restart (containers removed on stop)
- No reliance on upstream shell scripts

![Service Dependencies](./Readme/systemctl-list-dependencies-dokploy.png)
![Service Status](./Readme/systemctl-status-dokploy.png)
![Docker Stack](./Readme/docker-stack-ps-dokploy.png)

## Requirements

- Docker enabled with `live-restore = false` (required for swarm)
- Rootless Docker is not supported (swarm limitation)

## Quick Start

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-dokploy.url = "github:el-kurto/nix-dokploy";
    nix-dokploy.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-dokploy, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      modules = [
        nix-dokploy.nixosModules.default
        {
          virtualisation.docker.enable = true;
          virtualisation.docker.daemon.settings.live-restore = false;

          services.dokploy.enable = true;
          services.dokploy.database.passwordFile = "/var/lib/secrets/dokploy-db-password";
          services.dokploy.auth.secretFile = "/var/lib/secrets/dokploy-auth-secret";
          services.dokploy.encryption.keyFile = "/var/lib/secrets/dokploy-encryption-key";
        }
      ];
    };
  };
}
```

Generate secret files on the host before deploying:

```bash
mkdir -p /var/lib/secrets
openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
openssl rand -hex 32 > /var/lib/secrets/dokploy-auth-secret
openssl rand -hex 32 > /var/lib/secrets/dokploy-encryption-key
```

Dokploy will be available at `http://your-server-ip:3000`

## Configuration

### General

| Option | Default | Description |
|--------|---------|-------------|
| `dataDir` | `/var/lib/dokploy` | Data directory |
| `image` | `dokploy/dokploy:v0.30.2` | Dokploy Docker image |
| `environment` | `{}` | Environment variables for the Dokploy container |
| `lxc` | `false` | LXC compatibility mode (e.g. Proxmox) |

```nix
services.dokploy.environment = {
  TZ = "Europe/Amsterdam";
};
```

### Port

| Option | Default | Description |
|--------|---------|-------------|
| `port` | `"3000:3000"` | Port binding for web UI |
| `hostPortMode` | `false` | Use `"host"` port mode instead of `"ingress"` |

Docker bypasses host firewall rules, so `"3000:3000"` exposes the port to the internet regardless of iptables/nftables.

Once Traefik is set up as a reverse proxy, disable direct access:

```nix
services.dokploy.port = null;
```

### Secrets

| Option | Default | Description |
|--------|---------|-------------|
| `database.passwordFile` | — (required) | Path to file containing the PostgreSQL password |
| `auth.secretFile` | — (required) | Path to file containing the Better Auth secret |
| `encryption.keyFile` | — (required) | Path to file containing the encryption-at-rest key |

Each option points to a root-readable file on the host (generated in [Quick Start](#quick-start)). On deploy, each file becomes a Docker secret, passed to the containers via `*_FILE` environment variables. Never pass secrets via `services.dokploy.environment` — those values end up world-readable in the Nix store.

Since Dokploy v0.29.12, environment variables are encrypted at rest (AES-256-GCM) using the key from `encryption.keyFile`. Without a dedicated key, Dokploy would derive one from the auth secret, making it impossible to rotate safely — which is why this module requires all three.

#### Rotating secrets

Docker secrets are immutable — the deploy script creates each secret once and never updates it. Rotation always ends the same way, run as root:

```bash
docker stack rm dokploy
docker secret rm dokploy_postgres_password   # or dokploy_auth_secret
sudo nixos-rebuild switch
```

What happens before that depends on the secret:

**Database password** — change it in the running PostgreSQL container first:

```bash
openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
docker exec -it $(docker ps --filter "name=dokploy_postgres" -q) psql -U dokploy -d dokploy
```

```sql
ALTER USER dokploy WITH PASSWORD 'contents-of-password-file';
```

**Auth secret** — migrate 2FA records in the running Dokploy container first:

```bash
NEW_SECRET=$(openssl rand -hex 32)
DOKPLOY_CONTAINER=$(docker ps --filter "name=dokploy_dokploy" --format "{{.ID}}" | head -n1)
docker exec \
    -e OLD_SECRET="$(cat /var/lib/secrets/dokploy-auth-secret)" \
    -e NEW_SECRET="$NEW_SECRET" \
    "$DOKPLOY_CONTAINER" \
    sh -c "cd /app && pnpm run migrate-auth-secret"
echo "$NEW_SECRET" > /var/lib/secrets/dokploy-auth-secret
```

> If you ever ran Dokploy v0.29.12+ before `encryption.keyFile` was set, values encrypted back then are still keyed to the old auth secret until re-saved — re-save them all before rotating.

**Encryption key** — never rotate it. Encrypted values cannot be re-keyed in bulk; a changed key makes them unreadable. Keep an offsite copy: database backups contain the encrypted values, so restoring one without the original key means re-entering every stored environment variable by hand.

### Swarm

| Option | Default | Description |
|--------|---------|-------------|
| `swarm.advertiseAddress` | `"private"` | IP address Docker Swarm advertises |
| `swarm.autoRecreate` | `false` | Recreate swarm on IP change during restart |

```nix
services.dokploy.swarm.advertiseAddress = "private";  # first private IP (default)
services.dokploy.swarm.advertiseAddress = "public";   # public IP via ifconfig.me

# custom command
services.dokploy.swarm.advertiseAddress = {
  command = "tailscale ip -4 | head -n1";
  extraPackages = [ pkgs.tailscale ];
};

# recreate swarm if IP changes (safe for single-node only)
services.dokploy.swarm.autoRecreate = true;
```

Using `"public"` exposes swarm management ports (2377, 7946, 4789) to the internet. Consider Tailscale/WireGuard or private networking instead.

### Traefik

| Option | Default | Description |
|--------|---------|-------------|
| `traefik.image` | `traefik:v3.7.11` | Traefik Docker image |
| `traefik.extraArgs` | `[]` | Extra `docker run` flags |
| `traefik.certificates` | `{}` | TLS certificate pairs |
| `traefik.dynamicConfig` | `{}` | Dynamic config as Nix attrsets (generates YAML) |
| `traefik.files` | `{}` | Files to place in the dynamic config directory |

#### Extra arguments

```nix
services.dokploy.traefik.extraArgs = [
  "-e CF_API_EMAIL=user@example.com"
  "-e CF_API_KEY=your_api_key"
  "-v /path/to/certs:/certs"
];
```

#### TLS Certificates

Creates a subdirectory under `traefik/dynamic/certificates/<name>/` with `chain.crt`, `privkey.key`, and a `certificate.yml`.

```nix
services.dokploy.traefik.certificates."cloudflare-origin" = {
  certFile = "/var/lib/secrets/cloudflare-origin-ca.pem";
  keyFile = "/var/lib/secrets/cloudflare-origin-ca-key.pem";
};
```

#### Dynamic Configuration

Each key becomes a `.yml` file in the Traefik dynamic config directory.

```nix
services.dokploy.traefik.dynamicConfig."cloudflare-client-auth" = {
  tls.options.default.clientAuth = {
    caFiles = [ "/etc/dokploy/traefik/dynamic/files/cloudflare-origin-pull-ca.pem" ];
    clientAuthType = "RequireAndVerifyClientCert";
  };
};
```

#### Files

Files are placed at `traefik/dynamic/files/<name>` on the host and visible in the container at `/etc/dokploy/traefik/dynamic/files/<name>`.

```nix
services.dokploy.traefik.files."cloudflare-origin-pull-ca.pem" = pkgs.fetchurl {
  url = "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem";
  sha256 = "...";
};
```

## License

[MIT License](./LICENSE)

Dokploy itself is [Apache 2.0 with additional terms](https://github.com/Dokploy/dokploy/blob/canary/LICENSE.MD).
