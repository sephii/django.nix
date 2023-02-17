{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.django;
  withDefault = default: val: if val == null then default else val;
  startsWith = needle: haystack:
    substring 0 (stringLength needle) haystack == needle;
  isLocalPath = path: startsWith "/" path;

  siteOpts = { name, ... }:
    let
      instanceName = name;
      instanceConfig = cfg.sites.${name};
    in {
      options = {
        package = mkOption { type = types.package; };
        staticFilesPackage = mkOption { type = types.package; };
        manageScript = mkOption {
          type = types.package;
          readOnly = true;
          visible = false;
        };

        hostname = mkOption { type = types.str; };
        aliases = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description =
            "Additional hostnames that should redirect to `hostname`.";
        };

        settingsModule = mkOption {
          type = types.nullOr types.str;
          default = "${instanceConfig.package.pname}.config.settings.base";
          description = ''
            Import path for the settings module."
          '';
        };

        wsgiModule = mkOption {
          type = types.nullOr types.str;
          default = "${instanceConfig.package.pname}.config.wsgi";
          description = ''
            Import path for the wsgi module."
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

        user = mkOption {
          type = types.str;
          default = name;
          description =
            "The user to use to run the maintenance tasks and the gunicorn service.";
        };

        group = mkOption {
          type = types.str;
          default = name;
          description =
            "The group to use to run the maintenance tasks and the gunicorn service.";
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = [ instanceConfig.package.python.pkgs.gunicorn instanceConfig.package.python.pkgs.gevent ];
          description =
            "Extra packages to install in the environment.";
        };

        databaseUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          description =
            ''DSN for database connection. If not set, will default to using a
            local PostgreSQL connection to a database with the instance name. If
            set, you’re responsible of creating the database (and database user)
            yourself.'';
        };

        baseDir = mkOption {
          type = types.str;
          default = "/var/www/${name}";
          description = "Base directory where files relative to the site will be placed.";
        };
      };

      config = { manageScript = siteConfigs.${name}.manageScript; };
    };

  siteToConfig = instanceName: instanceConfig:
    let
      secretKeyFile = "${instanceConfig.baseDir}/secret_key";
      mediaDir = "${instanceConfig.baseDir}/media";

      environment = (mapAttrsToList (name: value: ''${name}="${value}"'') ({
        DJANGO_SETTINGS_MODULE = instanceConfig.settingsModule;
        DATABASE_URL = if instanceConfig.databaseUrl == null then "postgresql:///${instanceName}" else instanceConfig.databaseUrl;
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

      dependencyEnv = instanceConfig.package.python.withPackages (ps: [
        instanceConfig.package
      ] ++ instanceConfig.extraPackages);

      manageScriptNoSudo = pkgs.writeScriptBin "manage-${instanceName}-nosudo" ''
        #!${pkgs.bash}/bin/bash
        ${exports}
        ${dependencyEnv.interpreter} -m django $@
      '';
    in {
      manageScript = pkgs.writeScriptBin "manage-${instanceName}" ''
        #!${pkgs.bash}/bin/bash
        sudo -u ${instanceConfig.user} ${manageScriptNoSudo}/bin/manage-${instanceName}-nosudo $@
      '';

      createSecretKeyTask = {
        description = "Create secret key for ${instanceName}";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = instanceConfig.user;
          Group = instanceConfig.group;
        };
        script = ''
          test -s ${secretKeyFile} || ${dependencyEnv.interpreter} -c "from django.core.management.utils import get_random_secret_key; print(f'SECRET_KEY=\"{get_random_secret_key()}\"')" > ${secretKeyFile} && exit 0
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
          User = instanceConfig.user;
          Group = instanceConfig.group;
          Environment = environment;
          EnvironmentFile = environmentFiles;
        };
        script = ''
          ${dependencyEnv.interpreter} -m django migrate --noinput
        '';
      };

      gunicornService = {
        description = "Gunicorn daemon for ${instanceName}";
        wantedBy = [ "multi-user.target" ];
        after = [ "maintenance-${instanceName}.service" ];
        serviceConfig = {
          User = instanceConfig.user;
          Group = instanceConfig.group;
          RuntimeDirectory = "gunicorn_${instanceName}";
          RuntimeDirectoryPreserve = true;
          # https://docs.gunicorn.org/en/stable/deploy.html#systemd
          ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
          KillMode = "mixed";
          Environment = environment;
          EnvironmentFile = environmentFiles;
          PrivateTmp = "true";
        };

        script = ''
          ${dependencyEnv.interpreter} -m gunicorn \
            --name gunicorn-${instanceName} \
            --pythonpath ${dependencyEnv}/${instanceConfig.package.python.sitePackages} \
            --bind unix:${gunicornSock} \
            --workers ${toString instanceConfig.nbWorkers} \
            --worker-class gevent \
            ${instanceConfig.wsgiModule}:application
        '';
      };

      databaseUser = if instanceConfig.databaseUrl == null then {
        name = instanceConfig.user;
        ensurePermissions = { "DATABASE ${instanceName}" = "ALL PRIVILEGES"; };
      } else null;

      caddyVhosts = {
        "${instanceConfig.hostname}:${toString instanceConfig.port}" = {
          serverAliases =
            map (hostname: "${hostname}:${toString instanceConfig.port}")
            instanceConfig.aliases;

          logFormat = ''
            output file ${config.services.caddy.logDir}/access-${instanceConfig.hostname}.log
            format console
          '';

          extraConfig = ''
            header -Server

            ${optionalString instanceConfig.disableACME ''
              tls internal
            ''}

            ${optionalString (instanceConfig.auth != null) ''
              basicauth * {
                ${instanceConfig.auth.user} ${instanceConfig.auth.password}
              }''}

            ${optionalString (localStaticPaths != "") ''
              @notStatic {
                not path ${localStaticPaths}
              }

              handle_path ${instanceConfig.mediaUrl}* {
                root * ${mediaDir}
                file_server
              }

              handle_path ${instanceConfig.staticUrl}* {
                root * ${instanceConfig.staticFilesPackage}
                file_server
              }''}

            reverse_proxy ${optionalString (localStaticPaths != "") "@notStatic"} unix/${gunicornSock} {
              # Upstream might take a while to respond while deploying
              lb_try_duration 15s

              transport http {
                dial_timeout 15s
              }
            }
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
        "d ${instanceConfig.baseDir} 0555 ${instanceConfig.user} caddy - -"
        "d ${mediaDir} 0755 ${instanceConfig.user} caddy - -"
        "f ${secretKeyFile} 0750 ${instanceConfig.user} ${instanceConfig.group} - -"
      ];
    };

  siteConfigs = mapAttrs siteToConfig cfg.sites;
in {
  options.django = {
    sites = mkOption { type = types.attrsOf (types.submodule siteOpts); default = { }; };
  };

  config = mkIf (cfg.sites != { }) ({
    environment.systemPackages =
      mapAttrsToList (site: conf: conf.manageScript) siteConfigs;

    services.postgresql = let
      users = filter (item: item != null)
        (mapAttrsToList (site: conf: conf.databaseUser) siteConfigs);
      databases = attrNames (filterAttrs (k: v: v.databaseUrl == null) cfg.sites);
    in {
      enable = users != { } || databases != [ ];
      ensureDatabases = databases;
      ensureUsers = users;
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

    users.users = listToAttrs (map (conf: {
      name = conf.user;
      value = {
        isSystemUser = true;
        group = conf.group;
      };
    }) (attrValues cfg.sites));

    users.groups = listToAttrs (map (conf: {
      name = conf.group;
      value = { };
    }) (attrValues cfg.sites));
  });
}
