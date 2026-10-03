{
  cfg,
  lib,
}: let
  secretNames = ["postgres_password" "auth_secret" "encryption_key"];
in {
  version = "3.8";

  services = {
    postgres = {
      image = "postgres:16";
      environment = {
        POSTGRES_USER = "dokploy";
        POSTGRES_DB = "dokploy";
        POSTGRES_PASSWORD_FILE = "/run/secrets/postgres_password";
      };
      secrets = [
        {
          source = "postgres_password";
          target = "/run/secrets/postgres_password";
        }
      ];
      volumes = [
        "dokploy-postgres-database:/var/lib/postgresql/data"
      ];
      networks = {
        dokploy-network = {
          aliases = ["dokploy-postgres"];
        };
      };
      deploy = {
        placement.constraints = ["node.role == manager"];
        restart_policy.condition = "any";
      };
    };

    dokploy =
      {
        inherit (cfg) image;
        environment =
          {
            ADVERTISE_ADDR = "\${ADVERTISE_ADDR}";
            POSTGRES_PASSWORD_FILE = "/run/secrets/postgres_password";
            BETTER_AUTH_SECRET_FILE = "/run/secrets/auth_secret";
            ENCRYPTION_KEY_FILE = "/run/secrets/encryption_key";
          }
          // cfg.environment;
        networks = {
          dokploy-network = {
            aliases = ["dokploy-app"];
          };
        };
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock"
          "${cfg.dataDir}:/etc/dokploy"
          "dokploy-docker-config:/root/.docker"
        ];
        depends_on = ["postgres"];
        deploy =
          {
            replicas = 1;
            placement.constraints = ["node.role == manager"];
            update_config = {
              parallelism = 1;
              order = "stop-first";
            };
            restart_policy.condition = "any";
          }
          // lib.optionalAttrs cfg.lxc {
            endpoint_mode = "dnsrr";
          };
        secrets =
          map (name: {
            source = name;
            target = "/run/secrets/${name}";
          })
          secretNames;
      }
      // lib.optionalAttrs (cfg.port != null) {
        ports = let
          parts = lib.splitString ":" cfg.port;
        in
          if cfg.hostPortMode
          then [
            {
              target = lib.strings.toInt (lib.last parts);
              published = lib.strings.toInt (builtins.head parts);
              mode = "host";
            }
          ]
          else [cfg.port];
      };
  };

  networks = {
    dokploy-network = {
      name = "dokploy-network";
      driver = "overlay";
      attachable = true;
    };
  };

  volumes = {
    dokploy-postgres-database = {};
    dokploy-docker-config = {};
  };

  secrets = lib.listToAttrs (map (name: {
      inherit name;
      value = {
        external = true;
        name = "dokploy_${name}";
      };
    })
    secretNames);
}
