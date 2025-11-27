# nix-dokploy

[![Build](https://github.com/el-kurto/nix-dokploy/actions/workflows/build.yml/badge.svg)](https://github.com/el-kurto/nix-dokploy/actions/workflows/build.yml)

A **NixOS module** that runs [Dokploy](https://dokploy.com/) (a self-hosted PaaS / deployment platform) using declarative systemd units.

⚠️ This module is **NixOS-only**. It integrates directly with `systemd.services` and `systemd.tmpfiles`, so it will not work on nix-darwin, home-manager, or plain nixpkgs environments.

## ✨ Features

- `dokploy-stack.service` and `dokploy-traefik.service` systemd units
- Proper service ordering (`docker.service` → `dokploy-stack.service` → `dokploy-traefik.service`)
- Automatic state directory creation via `systemd.tmpfiles`
- Clean `ExecStop` + `ExecStopPost` handling (containers removed on stop/restart)
- No reliance on upstream shell scripts

![Service Dependencies](./Readme/systemctl-list-dependencies-dokploy.png)
![Service Status](./Readme/systemctl-status-dokploy.png)
![Docker Stack](./Readme/docker-stack-ps-dokploy.png)

## 📋 Requirements

- Docker must be enabled
- Docker live-restore must be disabled (required for swarm)
- Rootless Docker is not supported (swarm limitation)

## 🚀 Quick Start

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
        }
      ];
    };
  };
}
```

That's it! Dokploy will be available at `http://your-server-ip:3000`

## ⚙️ Configuration Options

### Basic Options

| Option | Default | Description |
|--------|---------|-------------|
| `services.dokploy.dataDir` | `/etc/dokploy` | Data directory for Dokploy |
| `services.dokploy.image` | `dokploy/dokploy:latest` | Dokploy Docker image |
| `services.dokploy.port` | `"3000:3000"` | Port binding for web UI (⚠️ see note) |
| `services.dokploy.traefik.image` | `traefik:v3.5.0` | Traefik Docker image |
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

**Note on Multi-Node Swarms:**

Using `"public"` will expose swarm management ports (2377, 7946, 4789) to the internet. It seems unwise to do this unless you really know what you're doing and have properly secured these ports.

Some viable secure alternatives include:

- **Tailscale or WireGuard**: Use VPN IPs as advertise addresses for secure node-to-node communication
- **Private networks**: Use private IPs when nodes are on the same network
- **Cloud security groups**: Restrict access to specific trusted IPs if public addressing is necessary

For single-node setups (the most common case), the default `"private"` setting should work well. If your IP changes frequently (Tailscale, DHCP), enable `swarm.autoRecreate` to automatically handle address changes.

### Web UI Port Configuration

⚠️ **Recommendation**: Disable port 3000 once Traefik is configured to reverse proxy Dokploy.

1. Deploy with default port for initial configuration
2. Access Dokploy UI and configure Traefik reverse proxy
3. Redeploy with `port = null` to disable direct access

```nix
# Default - Exposes port 3000 to all interfaces (bypasses firewall!)
services.dokploy.port = "3000:3000";

# Disable direct port access (access through Traefik only)
services.dokploy.port = null;
```

## 📄 License

This NixOS module is licensed under the [MIT License](./LICENSE) - use it freely without restrictions.

**Note:** Dokploy itself is licensed under [Apache License 2.0 with additional terms](https://github.com/Dokploy/dokploy/blob/canary/LICENSE.MD). This module simply wraps Dokploy for NixOS deployment.
