# Docker stack configuration for Dokploy
{
  cfg,
  lib,
}: {
  version = "3.8";

  services = {
    postgres = {
      image = "postgres:16";
      environment = {
        POSTGRES_USER = "dokploy";
        POSTGRES_PASSWORD = "\${POSTGRES_PASSWORD}";
        POSTGRES_DB = "dokploy";
      };
      volumes = [
        "dokploy-postgres:/var/lib/postgresql/data"
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

    redis = {
      image = "redis:7";
      volumes = [
        "dokploy-redis:/data"
      ];
      networks = {
        dokploy-network = {
          aliases = ["dokploy-redis"];
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
        environment = {
          ADVERTISE_ADDR = "\${ADVERTISE_ADDR}";
        };
        networks = {
          dokploy-network = {
            aliases = ["dokploy-app"];
          };
        };
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock"
          "${cfg.dataDir}:/etc/dokploy"
          "dokploy:/root/.docker"
        ];
        depends_on = ["postgres" "redis"];
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
      }
      // lib.optionalAttrs (cfg.port != null) {
        ports = let
          parts = lib.splitString ":" cfg.port;
          len = builtins.length parts;
        in [
          ({
              target = lib.strings.toInt (lib.last parts);
              published = lib.strings.toInt (builtins.elemAt parts (len - 2));
              mode = "host";
            }
            // lib.optionalAttrs (len == 3) {
              host_ip = builtins.head parts;
            })
        ];
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
    dokploy-postgres = {};
    dokploy-redis = {};
    dokploy = {};
  };
}
