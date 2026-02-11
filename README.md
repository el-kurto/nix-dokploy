# nix-dokploy

[![Build](https://github.com/el-kurto/nix-dokploy/actions/workflows/build.yml/badge.svg)](https://github.com/el-kurto/nix-dokploy/actions/workflows/build.yml)

A **NixOS module** that runs [Dokploy](https://dokploy.com/) (a self-hosted PaaS / deployment platform) using declarative systemd units.

This module is **NixOS-only**. It integrates directly with `systemd.services` and `systemd.tmpfiles`, so it will not work on nix-darwin, home-manager, or plain nixpkgs environments.

## Features

- `dokploy-stack.service` and `dokploy-traefik.service` systemd units
- Proper service ordering (`docker.service` → `dokploy-stack.service` → `dokploy-traefik.service`)
- Automatic state directory creation via `systemd.tmpfiles`
- Clean `ExecStop` + `ExecStopPost` handling (containers removed on stop/restart)
- No reliance on upstream shell scripts

![Service Dependencies](./Readme/systemctl-list-dependencies-dokploy.png)
![Service Status](./Readme/systemctl-status-dokploy.png)
![Docker Stack](./Readme/docker-stack-ps-dokploy.png)

## Requirements

- Docker must be enabled
- Docker live-restore must be disabled (required for swarm)
- Rootless Docker is not supported (swarm limitation)

## Quick Start

Add to your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-dokploy.url = "github:el-kurto/nix-dokploy";
  };

  outputs = { self, nixpkgs, nix-dokploy, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      modules = [
        nix-dokploy.nixosModules.default
        {
          # Required dependencies
          virtualisation.docker.enable = true;
          virtualisation.docker.daemon.settings.live-restore = false;

          # Enable Dokploy
          services.dokploy.enable = true;
          services.dokploy.database.passwordFile = "/var/lib/secrets/dokploy-db-password";
        }
      ];
    };
  };
}
```

Generate a password file on the host before deploying:

```bash
mkdir -p /var/lib/secrets
openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
```

Dokploy will be available at `http://your-server-ip:3000`

## Configuration Options

### Basic Options

| Option | Default | Description |
|--------|---------|-------------|
| `services.dokploy.dataDir` | `/var/lib/dokploy` | Data directory for Dokploy |
| `services.dokploy.image` | `dokploy/dokploy:v0.28.4` | Dokploy Docker image |
| `services.dokploy.port` | `"3000:3000"` | Port binding for web UI (see note) |
| `services.dokploy.hostPortMode` | `false` | Use "host" port mode instead of "ingress" (bypasses Swarm routing mesh) |
| `services.dokploy.lxc` | `false` | Enable LXC compatibility (required for Proxmox) |
| `services.dokploy.database.passwordFile` | — (required) | Path to file containing the PostgreSQL password |
| `services.dokploy.database.useInsecureHardcodedPassword` | `false` | Use old hardcoded password (migration aid only, see below) |
| `services.dokploy.environment` | `{}` | Environment variables for Dokploy container |
| `services.dokploy.traefik.image` | `traefik:v3.6.7` | Traefik Docker image |
| `services.dokploy.traefik.extraArgs` | `[]` | Extra `docker run` flags for Traefik container |
| `services.dokploy.traefik.certificates` | `{}` | TLS certificate pairs to install for Traefik (see below) |
| `services.dokploy.traefik.dynamicConfig` | `{}` | Traefik dynamic config files as Nix attrsets (see below) |
| `services.dokploy.traefik.files` | `{}` | Files to inject into the Traefik dynamic config directory (see below) |
| `services.dokploy.swarm.autoRecreate` | `false` | Auto-recreate swarm when IP change is detected during service restart |

### Swarm Advertise Address

Control which IP address Docker Swarm advertises to other nodes:

```nix
# Use private IP (default - recommended for security)
services.dokploy.swarm.advertiseAddress = "private";

# Use public IP (see security note below)
services.dokploy.swarm.advertiseAddress = "public";

# Use a specific IP
services.dokploy.swarm.advertiseAddress = {
  command = "echo 192.168.1.100";
};

# Use Tailscale IP (recommended for multi-node)
services.dokploy.swarm.advertiseAddress = {
  command = "tailscale ip -4 | head -n1";
  extraPackages = [ pkgs.tailscale ];
};

# Auto-recreate swarm when IP change is detected during service restart
services.dokploy.swarm.autoRecreate = true;
```

### Environment Variables

You can set environment variables for the Dokploy container:

```nix
services.dokploy.environment = {
  TZ = "Europe/Amsterdam";
};
```

**Note on Multi-Node Swarms:**

Using `"public"` will expose swarm management ports (2377, 7946, 4789) to the internet. It seems unwise to do this unless you really know what you're doing and have properly secured these ports.

Some viable secure alternatives include:

- **Tailscale or WireGuard**: Use VPN IPs as advertise addresses for secure node-to-node communication
- **Private networks**: Use private IPs when nodes are on the same network
- **Cloud security groups**: Restrict access to specific trusted IPs if public addressing is necessary

For single-node setups (the most common case), the default `"private"` setting should work well. If your IP changes frequently (Tailscale, DHCP), enable `swarm.autoRecreate` to automatically handle address changes.

### Web UI Port Configuration

**Recommendation**: Disable port 3000 once Traefik is configured to reverse proxy Dokploy.

1. Deploy with default port for initial configuration
2. Access Dokploy UI and configure Traefik reverse proxy
3. Redeploy with `port = null` to disable direct access

```nix
# Default - Exposes port 3000 to all interfaces (bypasses firewall!)
services.dokploy.port = "3000:3000";

# Disable direct port access (access through Traefik only)
services.dokploy.port = null;
```

### Traefik Extra Arguments

Pass extra `docker run` flags to the Traefik container:

```nix
services.dokploy.traefik.extraArgs = [
  "-e CF_API_EMAIL=user@example.com"
  "-e CF_API_KEY=your_api_key"
  "-v /path/to/certs:/certs"
];
```

### Database Password

The PostgreSQL password is stored as a Docker secret. `database.passwordFile` is required and must point to a file containing the password.

```bash
openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
```

```nix
services.dokploy.database.passwordFile = "/var/lib/secrets/dokploy-db-password";
```

#### Upgrading from the old hardcoded password

Previous versions used a hardcoded PostgreSQL password. On upgrade, `nixos-rebuild` will fail with an error asking you to either set `database.passwordFile` or enable `database.useInsecureHardcodedPassword`.

**Option A: Keep the old password temporarily**

If you're not ready to migrate, add this to unblock the upgrade:

```nix
services.dokploy.database.useInsecureHardcodedPassword = true;
```

This continues using the old hardcoded password. A build warning will remind you to migrate.

**Option B: Migrate to a secure password**

> Complete these steps in order. The old stack must still be running for step 2.

1. Generate a new password file on the host:
   ```bash
   openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password
   ```

2. Change the password in the running PostgreSQL container:
   ```bash
   NEW_PW=$(cat /var/lib/secrets/dokploy-db-password)
   docker exec -e PGPASSWORD=amukds4wi9001583845717ad2 \
     $(docker ps --filter "name=dokploy_postgres" -q) \
     psql -U dokploy -d dokploy \
     -c "ALTER USER dokploy WITH PASSWORD '$NEW_PW'"
   ```

3. Deploy with `database.passwordFile` set:
   ```nix
   services.dokploy.database.passwordFile = "/var/lib/secrets/dokploy-db-password";
   ```

#### Rotating the password

Docker secrets are immutable, so the deploy script won't update an existing secret. To rotate the password:

1. Change the password in the running PostgreSQL container (same as step 2 of the migration above)
2. Write the new password to the file at `database.passwordFile`
3. Remove the stack so the secret is no longer in use: `docker stack rm dokploy`
4. Remove the old Docker secret: `docker secret rm dokploy_postgres_password`
5. Redeploy with `nixos-rebuild switch`

#### Recovery

If the password gets into a bad state, you can get a local superuser shell (no password needed):

```bash
docker exec -it $(docker ps --filter "name=dokploy_postgres" -q) psql -U dokploy -d dokploy
```

### Traefik TLS Certificates

Install TLS certificate pairs following Dokploy's directory convention. Each entry creates a subdirectory under `traefik/dynamic/certificates/<name>/` with `chain.crt`, `privkey.key`, and a generated `certificate.yml`.

```nix
services.dokploy.traefik.certificates."cloudflare-origin" = {
  certFile = "/var/lib/secrets/cloudflare-origin-ca.pem";
  keyFile = "/var/lib/secrets/cloudflare-origin-ca-key.pem";
};
```

### Traefik Dynamic Configuration

Generate arbitrary Traefik dynamic configuration YAML files from Nix attrsets. Each key becomes a `.yml` file in the Traefik dynamic config directory.

```nix
services.dokploy.traefik.dynamicConfig."cloudflare-client-auth" = {
  tls.options.default.clientAuth = {
    caFiles = [ "/etc/dokploy/traefik/dynamic/files/cloudflare-origin-pull-ca.pem" ];
    clientAuthType = "RequireAndVerifyClientCert";
  };
};
```

### Traefik Files

Inject files into the Traefik dynamic config directory. Files are placed at `traefik/dynamic/files/<name>` on the host and accessible in the container at `/etc/dokploy/traefik/dynamic/files/<name>`.

```nix
services.dokploy.traefik.files."cloudflare-origin-pull-ca.pem" = pkgs.fetchurl {
  url = "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem";
  sha256 = "...";
};
```

## License

This NixOS module is licensed under the [MIT License](./LICENSE) - use it freely without restrictions.

**Note:** Dokploy itself is licensed under [Apache License 2.0 with additional terms](https://github.com/Dokploy/dokploy/blob/canary/LICENSE.MD). This module simply wraps Dokploy for NixOS deployment.
