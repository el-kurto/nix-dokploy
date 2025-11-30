{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.dokploy;

  stackConfig = import ./dokploy-stack.nix {inherit cfg lib;};
  yamlFormat = pkgs.formats.yaml {};
  stackFile = yamlFormat.generate "dokploy-stack.yml" stackConfig;
in {
  options.services.dokploy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Dokploy stack containers and Traefik container";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/dokploy";
      description = "Directory to store Dokploy data";
    };

    database = {
      password = lib.mkOption {
        type = lib.types.str;
        default = "amukds4wi9001583845717ad2";
        description = ''
          PostgreSQL database password for Dokploy.

          WARNING: This password is hardcoded in Dokploy's source code and cannot be changed
          without breaking the application. Dokploy does not currently support custom database
          passwords. This is a known security issue (see Dokploy/dokploy#595).

          The default value matches what Dokploy expects internally.
        '';
      };
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "dokploy/dokploy:latest";
      description = ''
        Dokploy Docker image to use.
        Note: Check Dokploy's installation script for compatible Traefik versions
        when changing this.
      '';
    };

    lxc = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable compatibility mode for LXC containers (e.g. Proxmox).
        Adds "endpoint_mode: dnsrr" to the Dokploy service deployment configuration.
        This is required for Docker Swarm networking to work correctly inside LXC.
      '';
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "3000:3000";
      example = lib.literalExpression ''
        "3000:3000"                 # Default: expose on all interfaces (Docker bypasses firewall!)
        "127.0.0.1:3000:3000"       # Localhost only (secure, requires reverse proxy)
        "8080:3000"                 # Custom external port
        null                        # Disable direct access (use Traefik only)
      '';
      description = ''
        Port binding for Dokploy web UI.

        WARNING: Docker bypasses host firewall rules. Setting "3000:3000" exposes
        the port to the internet regardless of firewall configuration.

        Secure options:
        - Set to "127.0.0.1:3000:3000" for localhost-only access
        - Set to null to disable direct access (configure reverse proxy in Dokploy UI)

        Format: "[host:]port:containerPort" or null
      '';
    };

    traefik = {
      image = lib.mkOption {
        type = lib.types.str;
        default = "traefik:v3.6.1";
        description = ''
          Traefik Docker image to use.
          Default matches the version pinned in Dokploy's installation script.
          Changing this may cause compatibility issues with Dokploy.
        '';
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Extra arguments to pass to the Traefik container's docker run command.
          Can be used to pass environment variables, volumes, etc.
        '';
      };
    };

    swarm = {
      advertiseAddress = lib.mkOption {
        type = lib.types.oneOf [
          (lib.types.enum ["public" "private"])
          (lib.types.submodule {
            options = {
              command = lib.mkOption {
                type = lib.types.str;
                description = "Shell command that outputs an IP address";
                example = "ip route get 1 | awk '{print $7;exit}'";
              };
              extraPackages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [];
                example = lib.literalExpression "[ pkgs.tailscale pkgs.iproute2 ]";
                description = ''
                  Extra packages to make available to the command.
                  For example, if using tailscale, add pkgs.tailscale here.
                '';
              };
            };
          })
        ];
        default = "private";
        example = lib.literalExpression ''
          "public"                                     # Use public IP via ifconfig.me
          # or
          "private"                                    # Use first private IP from hostname -I
          # or
          { command = "echo 192.168.1.100"; }         # Static IP via command
          # or
          {
            command = "tailscale ip -4 | head -n1";  # Use Tailscale IP
            extraPackages = [ pkgs.tailscale ];
          }
        '';
        description = ''
          Docker Swarm advertise address configuration. Can be:

          - `"private"` (default): Use first private IP from hostname -I (more secure)
          - `"public"`: Use public IP via ifconfig.me (exposes swarm ports to internet)
          - `{ command = "..."; extraPackages = [...]; }`: Custom shell command that outputs an IP

          This is evaluated at service startup, allowing dynamic IP detection.

          For single-node setups, "private" is recommended for security.
          Only use "public" if you plan to add external nodes to the swarm.
        '';
      };

      autoRecreate = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Automatically recreate the swarm on service restart.

          When enabled, the swarm will be torn down and recreated every time
          the service starts, ensuring the advertise address is always current.

          This is safe for single-node Dokploy setups where no other services
          use Docker Swarm. Useful when IPs may change (e.g., Tailscale, DHCP).

          WARNING: Do not enable if you have other Docker Swarm services or
          multi-node setup.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.virtualisation.docker.enable;
        message = "Dokploy requires docker to be enabled";
      }
      {
        assertion = !config.virtualisation.docker.daemon.settings.live-restore;
        message = "Dokploy stack requires Docker daemon setting: `live-restore = false`";
      }
      {
        assertion = !config.virtualisation.docker.rootless.enable;
        message = "Dokploy stack does not support rootless Docker";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0777 root root -"
      "d ${cfg.dataDir}/traefik 0755 root root -"
      "d ${cfg.dataDir}/traefik/dynamic 0755 root root -"
    ];

    systemd.services.dokploy-stack = {
      description = "Dokploy Docker Swarm Stack";
      after = ["docker.service"];
      requires = ["docker.service"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = let
          script = pkgs.writeShellApplication {
            name = "dokploy-stack-start";
            excludeShellChecks = ["SC2034"];
            runtimeInputs =
              [pkgs.curl pkgs.docker pkgs.hostname pkgs.gawk]
              ++ (
                cfg.swarm.advertiseAddress.extraPackages or []
              );
            text = ''
              # Get advertise address based on configuration
              ${
                if cfg.swarm.advertiseAddress == "public"
                then ''
                  echo "Getting public IP address..."
                  advertise_addr="$(curl -s ifconfig.me)"
                ''
                else if cfg.swarm.advertiseAddress == "private"
                then ''
                  echo "Getting private IP address..."
                  advertise_addr="$(hostname -I | awk '{print $1}')"
                ''
                else ''
                  echo "Getting IP address from custom command..."
                  advertise_addr="$(${cfg.swarm.advertiseAddress.command})"
                ''
              }
              echo "Advertise address: $advertise_addr"

              # Validate IP address format (basic check)
              if [[ ! "$advertise_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "Error: '$advertise_addr' is not a valid IPv4 address" >&2
                exit 1
              fi

              # Check current swarm state
              swarm_active=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")
              current_addr=$(docker info --format '{{.Swarm.NodeAddr}}' 2>/dev/null || echo "")

              # Leave swarm if auto-recreate is enabled and address changed
              ${
                if cfg.swarm.autoRecreate
                then ''
                  if [[ "$swarm_active" == "active" ]] && [[ "$current_addr" != "$advertise_addr" ]]; then
                    echo "Advertise address changed ($current_addr -> $advertise_addr), recreating swarm..."
                    docker swarm leave --force
                    swarm_active="inactive"
                  fi
                ''
                else ""
              }

              # Initialize swarm if inactive
              if [[ "$swarm_active" != "active" ]]; then
                echo "Initializing Docker Swarm with advertise address $advertise_addr..."
                docker swarm init --advertise-addr "$advertise_addr"
              else
                echo "Docker Swarm already active"
              fi

              # Deploy Dokploy stack
              if docker stack ls --format '{{.Name}}' | grep -q '^dokploy$'; then
                echo "Dokploy stack already deployed, updating stack..."
              else
                echo "Deploying Dokploy stack..."
              fi

              ${
                if cfg.port == null
                then ''
                  echo "Web UI port binding disabled - access via Traefik only"
                ''
                else ''
                  echo "Web UI will be available on port binding: ${cfg.port}"
                ''
              }

              ADVERTISE_ADDR="$advertise_addr" \
              POSTGRES_PASSWORD="${cfg.database.password}" \
              docker stack deploy -c ${stackFile} --detach=false dokploy
            '';
          };
        in "${script}/bin/dokploy-stack-start";

        ExecStop = let
          script = pkgs.writeShellScript "dokploy-stack-stop" ''
            ${pkgs.docker}/bin/docker stack rm --detach=false dokploy || true
          '';
        in "${script}";
      };

      wantedBy = ["multi-user.target"];
    };

    systemd.services.dokploy-traefik = {
      description = "Dokploy Traefik container";
      after = ["docker.service" "dokploy-stack.service"];
      requires = ["docker.service" "dokploy-stack.service"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = let
          script = pkgs.writeShellApplication {
            name = "dokploy-traefik-start";
            runtimeInputs = [pkgs.docker];
            text = ''
              # Wait for Traefik configuration to be generated by Dokploy
              echo "Waiting for Dokploy to generate Traefik configuration..."
              timeout=60
              while [ ! -f "${cfg.dataDir}/traefik/traefik.yml" ]; do
                sleep 1
                timeout=$((timeout - 1))
                if [ "$timeout" -le 0 ]; then
                  echo "Error: Timed out waiting for traefik.yml"
                  exit 1
                fi
              done
              echo "Traefik configuration found."

              if docker ps -a --format '{{.Names}}' | grep -q '^dokploy-traefik$'; then
                echo "Starting existing Traefik container..."
                docker start dokploy-traefik
              else
                echo "Creating and starting Traefik container..."
                docker run -d \
                  --name dokploy-traefik \
                  --network dokploy-network \
                  --restart=always \
                  -v /var/run/docker.sock:/var/run/docker.sock \
                  -v ${cfg.dataDir}/traefik/traefik.yml:/etc/traefik/traefik.yml \
                  -v ${cfg.dataDir}/traefik/dynamic:/etc/dokploy/traefik/dynamic \
                  -p 80:80/tcp \
                  -p 443:443/tcp \
                  -p 443:443/udp \
                  ${lib.concatStringsSep " \\\n" cfg.traefik.extraArgs} \
                  ${cfg.traefik.image}
              fi
            '';
          };
        in "${script}/bin/dokploy-traefik-start";

        ExecStop = let
          script = pkgs.writeShellScript "dokploy-traefik-stop" ''
            ${pkgs.docker}/bin/docker stop dokploy-traefik || true
          '';
        in "${script}";
        ExecStopPost = let
          script = pkgs.writeShellScript "dokploy-traefik-rm" ''
            ${pkgs.docker}/bin/docker rm dokploy-traefik || true
          '';
        in "${script}";
      };

      wantedBy = ["multi-user.target"];
    };
  };
}
