{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.django;
  withDefault = default: val: if val == null then default else val;
  startsWith = needle: haystack:
    substring 0 (stringLength needle) haystack == needle;
  isLocalPath = path: startsWith "/" path;

  siteToConfig = instanceName: instanceConfig:
    let
      settingsModule =
        withDefault "${instanceConfig.package.pname}.config.settings.base"
        instanceConfig.settingsModule;

      wsgiModule = withDefault "${instanceConfig.package.pname}.config.wsgi"
        instanceConfig.wsgiModule;

      mediaDir = "/var/www/${instanceName}/media";
      secretKeyFile = "/var/www/${instanceName}/secret_key";

      environment = (mapAttrsToList (name: value: ''${name}="${value}"'') ({
        DJANGO_SETTINGS_MODULE = settingsModule;
        DATABASE_URL = "postgresql:///${instanceName}";
        ALLOWED_HOSTS = instanceConfig.hostname;
        MEDIA_ROOT = mediaDir;
        # The secret key is overridden by the contents of the secret key file
        SECRET_KEY = "";
        MEDIA_URL = instanceConfig.mediaUrl;
        STATIC_URL = instanceConfig.staticUrl;
        STATIC_ROOT = instanceConfig.staticFilesPackage;
      } // instanceConfig.extraEnv));

      environmentFiles = [ secretKeyFile ] ++ instanceConfig.extraEnvFiles;
      sourceEnvironmentFiles = ''
        set -a
        ${concatStringsSep "\n" (map (file: "source ${file}") environmentFiles)}
        set +a
      '';

      exports = ''
        export ${concatStringsSep " " environment}
        ${sourceEnvironmentFiles}
      '';

      gunicornRunDir = "/run/gunicorn_${instanceName}";
      gunicornSock = "${gunicornRunDir}/gunicorn.sock";

      localStaticPaths = concatStringsSep " " (map (path: "${path}*")
        (filter isLocalPath [
          instanceConfig.staticUrl
          instanceConfig.mediaUrl
        ]));

      dependencyEnv = instanceConfig.package.dependencyEnv.overrideAttrs
        (oldAttrs: { pathsToLink = [ "/lib" ]; });
    in {
      manageScript = pkgs.writeScriptBin "manage-${instanceName}" ''
        #!${pkgs.bash}/bin/bash
        ${exports}
        ${dependencyEnv}/bin/django-admin $@
      '';

      createSecretKeyTask = {
        description = "Create secret key for ${instanceName}";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = instanceName;
        };
        script = ''
          test -s ${secretKeyFile} || ${dependencyEnv}/bin/python -c "from django.core.management.utils import get_random_secret_key; print(f'SECRET_KEY=\"{get_random_secret_key()}\"')" > ${secretKeyFile} && exit 0
        '';
      };

      maintenanceTasks = {
        description = "Maintenance tasks for ${instanceName}";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "postgresql.service"
          "secret-key-${instanceName}.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          User = instanceName;
          Environment = environment;
          EnvironmentFile = environmentFiles;
        };
        script = ''
          ${exports}
          ${dependencyEnv}/bin/django-admin migrate --noinput
        '';
      };

      gunicornService = {
        description = "Gunicorn daemon for ${instanceName}";
        wantedBy = [ "multi-user.target" ];
        after = [ "maintenance-${instanceName}.service" ];
        serviceConfig = {
          User = instanceName;
          RuntimeDirectory = "gunicorn_${instanceName}";
          ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
          Environment = environment;
          EnvironmentFile = environmentFiles;
        };

        script = let
          gunicornEnv = instanceConfig.package.python.withPackages
            (ps: [ ps.gunicorn ps.setuptools ps.gevent ]);
        in ''
          ${gunicornEnv}/bin/gunicorn \
            --name gunicorn-${instanceName} \
            --pythonpath ${dependencyEnv}/${instanceConfig.package.python.sitePackages} \
            --bind unix:${gunicornSock} \
            --workers ${toString instanceConfig.nbWorkers} \
            --worker-class gevent \
            ${wsgiModule}:application
        '';
      };

      databaseUser = {
        name = instanceName;
        ensurePermissions = { "DATABASE ${instanceName}" = "ALL PRIVILEGES"; };
      };

      caddyVhosts = {
        "${instanceConfig.hostname}:${toString instanceConfig.port}" = {
          serverAliases =
            map (hostname: "${hostname}:${toString instanceConfig.port}")
            instanceConfig.aliases;
          extraConfig = ''
            ${optionalString instanceConfig.disableACME ''
              tls internal
            ''}

            ${optionalString (instanceConfig.auth != null) ''
              basicauth * {
                ${instanceConfig.auth.user} ${instanceConfig.auth.password}
              }''}

            ${if localStaticPaths != "" then ''
              @notStatic {
                not path ${localStaticPaths}
              }

              file_server ${instanceConfig.mediaUrl}* {
                root /var/www/${instanceName}
              }

              handle_path ${instanceConfig.staticUrl}* {
                root * ${instanceConfig.staticFilesPackage}
                file_server
              }

              reverse_proxy @notStatic unix/${gunicornSock}'' else ''
                reverse_proxy unix/${gunicornSock}
              ''}
          '';
        };
      } // (optionalAttrs (!isLocalPath instanceConfig.staticUrl) {
        "${instanceConfig.staticUrl}:${instanceConfig.port}" = {
          extraConfig = ''
            file_server {
              root ${instanceConfig.staticFilesPackage}
            }
          '';
        };
      }) // (optionalAttrs (!isLocalPath instanceConfig.mediaUrl) {
        "${instanceConfig.mediaUrl}:${instanceConfig.port}" = {
          extraConfig = ''
            file_server {
              root ${mediaDir}
            }
          '';
        };
      });

      staticDirs = [
        "d /var/www/${instanceName} 0555 ${instanceName} caddy - -"
        "d ${mediaDir} 0755 ${instanceName} caddy - -"
        "f ${secretKeyFile} 0750 ${instanceName} ${instanceName} - -"
      ];
    };

  siteConfigs = mapAttrs siteToConfig cfg.sites;
in {
  options.django = {
    sites = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          package = mkOption { type = types.package; };
          staticFilesPackage = mkOption { type = types.package; };

          hostname = mkOption { type = types.str; };
          aliases = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description =
              "Additional hostnames that should redirect to `hostname`.";
          };

          settingsModule = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Import path for settings module. If not set, defaults to "<packageName>.config.settings.base"
            '';
          };

          wsgiModule = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Import path for wsgi module. If not set, defaults to "<packageName>.config.wsgi"
            '';
          };

          port = mkOption {
            type = types.int;
            default = 443;
            description = ''
              HTTP port to listen to.
            '';
          };

          auth = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                user = mkOption { type = types.str; };
                password = mkOption { type = types.str; };
              };
            });
            default = null;
            description = ''
              If set, require an HTTP auth.
            '';
          };

          mediaUrl = mkOption {
            type = types.str;
            default = "/media/";
            description = "Path or URL to media files (ie. MEDIA_URL)";
          };

          staticUrl = mkOption {
            type = types.str;
            default = "/static/";
            description = "Path or URL to static files (ie. STATIC_URL)";
          };

          nbWorkers = mkOption {
            type = types.int;
            default = 1;
            description = "Number of gunicorn workers to start";
          };

          extraEnv = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = "Additional environment variables to export";
          };

          extraEnvFiles = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description =
              "Additional files to source as environment variables (useful for secrets)";
          };

          disableACME = mkOption {
            type = types.bool;
            default = false;
            description =
              "If true, the HTTPS certificate will be self-signed instead of requested through ACME";
          };
        };
      });
    };
  };

  config = mkIf (cfg.sites != [ ]) {
    environment.systemPackages =
      mapAttrsToList (site: conf: conf.manageScript) siteConfigs;

    services.postgresql = {
      enable = true;
      ensureDatabases = attrNames siteConfigs;
      ensureUsers = mapAttrsToList (site: conf: conf.databaseUser) siteConfigs;
    };

    systemd.tmpfiles.rules = [ "d /var/www 0755 root root - -" ]
      ++ builtins.concatLists
      (mapAttrsToList (site: conf: conf.staticDirs) siteConfigs);

    systemd.services = (attrsets.mapAttrs' (site: conf:
      attrsets.nameValuePair "gunicorn-${site}" conf.gunicornService)
      siteConfigs) // (attrsets.mapAttrs' (site: conf:
        attrsets.nameValuePair "secret-key-${site}" conf.createSecretKeyTask)
        siteConfigs) // (attrsets.mapAttrs' (site: conf:
          attrsets.nameValuePair "maintenance-${site}" conf.maintenanceTasks)
          siteConfigs);

    services.caddy = {
      enable = true;
      virtualHosts = foldl' (s1: s2: s1 // s2) { }
        (mapAttrsToList (site: conf: conf.caddyVhosts) siteConfigs);
    };

    users.users = lib.attrsets.mapAttrs (site: conf: {
      isSystemUser = true;
      group = site;
    }) siteConfigs;

    users.groups = lib.attrsets.mapAttrs (site: conf: { }) siteConfigs;
  };
}
