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

      exports = (concatStringsSep "\n"
        (mapAttrsToList (name: value: ''export ${name}="${value}"'') {
          DJANGO_SETTINGS_MODULE = settingsModule;
          DATABASE_URL = "postgresql:///${instanceName}";
          ALLOWED_HOSTS = concatStringsSep ","
            ([ instanceConfig.hostname ] ++ instanceConfig.aliases);
          MEDIA_ROOT = mediaDir;
          # The secret key is overridden by the contents of the secret key file
          SECRET_KEY = "";
          MEDIA_URL = instanceConfig.mediaUrl;
          STATIC_URL = instanceConfig.staticUrl;
        })) + ''

          source ${secretKeyFile}'';

      gunicornRunDir = "/run/gunicorn_${instanceName}";
      gunicornSock = "${gunicornRunDir}/gunicorn.sock";

      localStaticPaths = concatStringsSep " " (map (path: "${path}*")
        (filter isLocalPath [
          instanceConfig.staticUrl
          instanceConfig.mediaUrl
        ]));
    in {
      manageScript = pkgs.writeScriptBin "manage-${instanceName}" ''
        #!${pkgs.bash}/bin/bash
        ${exports}
        ${instanceConfig.package}/bin/django-admin $@
      '';

      createSecretKeyTask = {
        description = "Create secret key for ${instanceName}";
        serviceConfig = {
          Type = "oneshot";
          User = instanceName;
        };
        script = ''
          test ! -s ${secretKeyFile} && ${instanceConfig.package.python}/bin/python -c "from django.core.management.utils import get_random_secret_key; print(f'export SECRET_KEY=\"{get_random_secret_key()}\"')" > ${secretKeyFile}
        '';
        wantedBy = [ "multi-user.target" ];
      };

      maintenanceTasks = {
        description = "Maintenance tasks for ${instanceName}";
        requiredBy = [ "gunicorn-${instanceName}.service" ];
        requires = [ "postgresql.service" "secret-key-${instanceName}" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = instanceName;
        };
        script = ''
          ${exports}
          ${instanceConfig.package}/bin/django-admin migrate --noinput
        '';
      };

      gunicornService = {
        description = "Gunicorn daemon for ${instanceName}";
        wantedBy = [ "multi-user.target" ];
        requires = [
          "postgresql.service"
          "maintenance-${instanceName}.service"
          "secret-key-${instanceName}.service"
        ];
        after = [ "network.target" ];
        serviceConfig = {
          User = instanceName;
          RuntimeDirectory = "gunicorn_${instanceName}";
          ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
        };
        script = ''
          ${exports}
          ${instanceConfig.package}/bin/gunicorn \
            --name gunicorn-${instanceName} \
            --pythonpath ${instanceConfig.package} \
            --bind unix:${gunicornSock} \
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
            ${optionalString (instanceConfig.auth != null) ''
              basicauth * {
                ${instanceConfig.auth.user} ${instanceConfig.auth.password}
              }''}

            ${if localStaticPaths != "" then ''
              @notStatic {
                not path ${localStaticPaths}
              }

              file_server ${instanceConfig.mediaUrl} {
                root /var/www/${instanceName}
              }

              file_server ${instanceConfig.staticUrl} {
                root ${instanceConfig.staticFilesPackage}
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
