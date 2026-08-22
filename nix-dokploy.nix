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

  deploySnippet = let
    secretCheck = secretName: file: ''
      if [ ! -f "${file}" ]; then
        echo "Error: secret file not found: ${file}"
        exit 1
      fi

      if ! docker secret inspect ${secretName} >/dev/null 2>&1; then
        echo "Creating Docker secret ${secretName} from ${file}..."
        docker secret create ${secretName} "${file}"
      fi
    '';

    secretChecks = lib.concatStringsSep "\n" [
      (secretCheck "dokploy_postgres_password" cfg.database.passwordFile)
      (secretCheck "dokploy_auth_secret" cfg.auth.secretFile)
      (secretCheck "dokploy_encryption_key" cfg.encryption.keyFile)
    ];
  in ''
    ${secretChecks}

    ADVERTISE_ADDR="$advertise_addr" \
      docker stack deploy -c ${stackFile} --detach=false dokploy
  '';
in {
  imports = [
    (lib.mkRemovedOptionModule ["services" "dokploy" "auth" "useInsecureHardcodedSecret"] ''
      Dokploy v0.29.12+ encrypts environment variables at rest with a key derived
      from BETTER_AUTH_SECRET, so running with the well-known hardcoded secret is
      no longer supported: it would encrypt your data with a publicly known key,
      and rotating the secret afterwards would leave the already-encrypted values
      unreadable until each one is re-saved by hand.

      If you are still on the hardcoded secret, migrate now:

        1. Pin nix-dokploy to the last revision that supported this option:

             nix-dokploy.url = "github:el-kurto/nix-dokploy/9b04a58467be7b0f633492602c9eb02321c380b1";

        2. Follow "Upgrading from the old hardcoded secret" in that revision's
           README (run migrate-auth-secret, then set auth.secretFile).

        3. Remove the input pin and this option, and rebuild.
    '')
    (lib.mkRemovedOptionModule ["services" "dokploy" "database" "useInsecureHardcodedPassword"] ''
      Running with the well-known hardcoded PostgreSQL password from Dokploy's
      source code is no longer supported. Migrate to a real password — this
      works against your running install without pinning anything:

        1. Generate a password file:

             openssl rand -base64 32 > /var/lib/secrets/dokploy-db-password

        2. Change the password in the running PostgreSQL container. As root,
           open a psql shell:

             docker exec -it $(docker ps --filter "name=dokploy_postgres" -q) psql -U dokploy -d dokploy

           and set the password to the contents of the file:

             ALTER USER dokploy WITH PASSWORD 'contents-of-password-file';

        3. Remove this option, set database.passwordFile to the file path,
           and rebuild.

      To defer migration, pin nix-dokploy to the last revision that supported
      this option:

        nix-dokploy.url = "github:el-kurto/nix-dokploy/273cec63b0de314845bc8dc7fdeabe9685cfc742";
    '')
  ];

  options.services.dokploy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Dokploy stack containers and Traefik container";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/dokploy";
      description = "Directory to store Dokploy data";
    };

    database = {
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to a file containing the PostgreSQL password for Dokploy.
          The file must be readable by root and will be used as a Docker secret.
        '';
        example = "/var/lib/secrets/dokploy-db-password";
      };
    };

    auth = {
      secretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to a file containing the Better Auth secret for Dokploy.
          The file must be readable by root and will be used as a Docker secret.

          Since Dokploy v0.29.12, this secret also derives the key used to
          encrypt environment variables at rest unless encryption.keyFile is
          set — do not rotate it without setting encryption.keyFile first.
        '';
        example = "/var/lib/secrets/dokploy-auth-secret";
      };
    };

    encryption = {
      keyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to a file containing a dedicated key for Dokploy's
          encryption of environment variables at rest (Dokploy v0.29.12+).
          The file must be readable by root and will be used as a Docker
          secret, passed to Dokploy via ENCRYPTION_KEY_FILE.

          Required. Without it, Dokploy derives the encryption key from
          the Better Auth secret, which makes auth.secretFile impossible
          to rotate safely.

          Note: values encrypted before this key was set remain encrypted
          under the auth-secret-derived key; Dokploy re-encrypts each value
          with this key the next time it is saved.
        '';
        example = "/var/lib/secrets/dokploy-encryption-key";
      };
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "dokploy/dokploy:v0.30.2";
      description = ''
        Dokploy Docker image to use.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Environment variables to pass to the Dokploy container.
      '';
      example = {
        TZ = "Europe/Amsterdam";
      };
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

    hostPortMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use "host" port publishing mode instead of the default "ingress" mode.
        Host mode binds ports directly on the host, bypassing the Swarm routing mesh.
        More efficient for single-node setups.
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

    traefik = {
      image = lib.mkOption {
        type = lib.types.str;
        default = "traefik:v3.7.11";
        description = ''
          Traefik Docker image to use.
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

      certificates = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            certFile = lib.mkOption {
              type = lib.types.str;
              description = "Path to the certificate chain file on the host.";
            };
            keyFile = lib.mkOption {
              type = lib.types.str;
              description = "Path to the private key file on the host.";
            };
          };
        });
        default = {};
        description = ''
          TLS certificates to install for Traefik.
          Each certificate is stored following Dokploy's convention under
          the traefik/dynamic/certificates/ directory.
        '';
      };

      dynamicConfig = lib.mkOption {
        type = lib.types.attrsOf yamlFormat.type;
        default = {};
        description = ''
          Traefik dynamic configuration files as Nix attribute sets.
          Each key generates a YAML file in the Traefik dynamic config directory.
        '';
      };

      files = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = ''
          Files to make available inside the Traefik dynamic config directory.
          Each key is the filename, value is the source path on the host.
          Files are accessible in the container at /etc/dokploy/traefik/dynamic/files/<name>.
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
      {
        assertion = cfg.database.passwordFile != null;
        message = ''
          Dokploy uses a Docker secret for the PostgreSQL password. You must set:

            services.dokploy.database.passwordFile = "/var/lib/secrets/dokploy-db-password";

          See the "Secrets" section in the README.
        '';
      }
      {
        assertion = cfg.auth.secretFile != null;
        message = ''
          Dokploy uses a Docker secret for the Better Auth secret. You must set:

            services.dokploy.auth.secretFile = "/var/lib/secrets/dokploy-auth-secret";

          See the "Secrets" section in the README.
        '';
      }
      {
        assertion = cfg.encryption.keyFile != null;
        message = ''
          Dokploy v0.29.12+ encrypts environment variables at rest. Without a
          dedicated key it derives one from the Better Auth secret, making
          auth.secretFile impossible to rotate safely, so this module requires:

            services.dokploy.encryption.keyFile = "/var/lib/secrets/dokploy-encryption-key";

          Generate it once and never rotate it:

            openssl rand -hex 32 > /var/lib/secrets/dokploy-encryption-key

          Safe for existing installs: values encrypted before the key was set
          (only possible if you overrode image to v0.29.12+ earlier) remain
          readable and are re-encrypted with this key as each one is saved.

          See the "Secrets" section in the README.
        '';
      }
      {
        assertion = let
          tag = builtins.match ".*:v([0-9.]+)" cfg.image;
        in
          tag == null || lib.versionAtLeast (builtins.head tag) "0.29.9";
        message = ''
          image is set to ${cfg.image}, but Dokploy versions before v0.29.9
          require the redis service for their deployment queue, which this
          module no longer deploys (upstream dropped redis in v0.29.9).

          To run an older Dokploy, pin nix-dokploy to the last revision that
          deployed redis:

            nix-dokploy.url = "github:el-kurto/nix-dokploy/9b04a58467be7b0f633492602c9eb02321c380b1";
        '';
      }
      {
        assertion = !(cfg.environment ? ENCRYPTION_KEY || cfg.environment ? ENCRYPTION_KEY_FILE);
        message = ''
          Do not set ENCRYPTION_KEY or ENCRYPTION_KEY_FILE via
          services.dokploy.environment: those values end up world-readable in
          the Nix store, and Dokploy prefers ENCRYPTION_KEY over the
          module-managed ENCRYPTION_KEY_FILE, silently ignoring
          encryption.keyFile.

          Move the key value into a root-readable file and set:

            services.dokploy.encryption.keyFile = "/var/lib/secrets/dokploy-encryption-key";

          The file must contain your existing key, byte for byte — data
          already encrypted under it becomes unreadable with any other value.
        '';
      }
    ];

    systemd.tmpfiles.rules = let
      containerCertDir = "/etc/dokploy/traefik/dynamic/certificates";

      certRules = lib.concatLists (lib.mapAttrsToList (name: cert: let
          dir = "${cfg.dataDir}/traefik/dynamic/certificates/${name}";
          certYaml = yamlFormat.generate "certificate-${name}.yml" {
            tls.certificates = [
              {
                certFile = "${containerCertDir}/${name}/chain.crt";
                keyFile = "${containerCertDir}/${name}/privkey.key";
              }
            ];
          };
        in [
          "d ${dir} 0755 root root -"
          "C+ ${dir}/chain.crt 0400 root root - ${cert.certFile}"
          "C+ ${dir}/privkey.key 0400 root root - ${cert.keyFile}"
          "C+ ${dir}/certificate.yml - - - - ${certYaml}"
        ])
        cfg.traefik.certificates);

      dynamicConfigRules =
        lib.mapAttrsToList (
          name: value: "C+ ${cfg.dataDir}/traefik/dynamic/${name}.yml - - - - ${yamlFormat.generate "${name}.yml" value}"
        )
        cfg.traefik.dynamicConfig;

      filesDirRules = lib.optionals (cfg.traefik.files != {}) [
        "d ${cfg.dataDir}/traefik/dynamic/files 0755 root root -"
      ];

      filesRules =
        lib.mapAttrsToList (
          name: value: "C+ ${cfg.dataDir}/traefik/dynamic/files/${name} - - - - ${value}"
        )
        cfg.traefik.files;
    in
      [
        "d ${cfg.dataDir} 0700 root root -"
        "d ${cfg.dataDir}/traefik 0755 root root -"
        "d ${cfg.dataDir}/traefik/dynamic 0755 root root -"
      ]
      ++ lib.optionals (cfg.dataDir != "/etc/dokploy") [
        "L /etc/dokploy - - - - ${cfg.dataDir}"
      ]
      ++ certRules
      ++ dynamicConfigRules
      ++ filesDirRules
      ++ filesRules;

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

              ${deploySnippet}
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
              echo "Waiting for Dokploy to generate Traefik configuration..."
              timeout=120
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
                  ${lib.concatMapStringsSep " \\\n  " lib.escapeShellArg (cfg.traefik.extraArgs ++ [cfg.traefik.image])}
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
