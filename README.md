# django.nix: helper for Django deployments on NixOS

django.nix is a [NixOS](https://nixos.org/) module that helps you deploy Django
websites. Use it like this (in your `configuration.nix`):

```nix
{
  django.sites = {
    # The key should be the unique instance name, so if you want multiple
    # instances of the same site make sure you include the environment name
    # in the key (eg. prod)
    # See below for places where the instance name is used
    mysite_prod = {
      # Your Django project as a Python project (see below for required structure)
      package = pkgs.mysite;
      # The derivation containing your static files, collected by Django (see
      # the docs of the `staticFilesPackage` option below for details)
      staticFilesPackage = pkgs.mysite-static;
      hostname = "mysite.com";
      # Requests to www.mysite.com will be redirected to mysite.com
      aliases = [ "www.mysite.com" ];
      settingsModule = "mysite.config.settings.prod";
    };
  };
}
```

This will:

* Create a system user for the site (named after the name of the instance)
* Generate a secret key if necessary
* Set up a gunicorn service (named `gunicorn-{instance_name}`)
* Create a `manage-{instance_name}` executable to easily run management commands
* Make sure Postgresql is installed and that a user and a database with the instance name exist
* Create a Caddy configuration with automatic HTTPS
* Run the `migrate` command on activation

Have a look at the [django.nix example](https://github.com/sephii/django.nix-example) and the [Django site packaged
with Nix example](https://github.com/sephii/django-nix-package-example) for working examples.

## Options

### `package`

**Mandatory**

Derivation that contains your Django project.

This derivation must include a `python` passthru that points to the Python derivation used to build
your package (poetry2nix’s `mkPoetryApplication` does that by default).

### `staticFilesPackage`

**Mandatory**

Derivation that contains your project static files. Usually the result of
`collectstatic`. You can create this derivation from your site derivation with
something like this:

``` nix
let
  pythonEnv = package.python.withPackages (_: [ package ]);
in stdenv.mkDerivation {
  pname = "${package.pname}-static";
  version = package.version;
  src = ./.;
  buildPhase = ''
    export STATIC_ROOT=$out
    export DJANGO_SETTINGS_MODULE=mysite.config.settings.base
    export MEDIA_ROOT=/dev/null
    export SECRET_KEY=dummy
    export DATABASE_URL=sqlite://:memory:
    ${pythonEnv.interpreter} -m django collectstatic --noinput
  '';
  phases = [ "buildPhase" ];
}
```

Feel free to adapt this if you use external assets builders such as Webpack.

### `extraPackages`

Default value: `[ python.pkgs.gunicorn python.pkgs.gevent ]`

Extra Python packages to install in the environment. If you set this option,
make sure to include the `gunicorn` and `gevent` packages somehow (either by
adding them as a dependency of your package, or by adding them to this option).

### `hostname`

**Mandatory**

The hostname used to access your website. You can make other hostnames point to
your site by setting `aliases`.

### `aliases`

Default value: `[]`

A list of hostnames that will redirect to your `hostname`.

### `settingsModule`

Default value: `"<packageName>.config.settings.base"`

A dotted Python path that points to the settings module to use.

### `wsgiModule`

Default value: `"<packageName>.config.wsgi"`

A dotted Python path that points to the WSGI module to use.

### `port`

Default value: `443`

The HTTP port your site should be served from.

### `auth`

Default value: `null`

Require an HTTP auth to access your site. You should set it like this:
`{ user = "jane.doe"; password = "foobar"; }`

### `mediaUrl`

Default value: `/media/`

URL to your media files (ie. `MEDIA_URL`).

### `staticUrl`

Default value: `/static/`

URL to your static files (ie. `STATIC_URL`).

### `nbWorkers`

Default value: `1`

Number of gunicorn workers to run.

### `extraEnv`

Default value: `[]`

Additional files to source as environment variables. Variables defined in them
can be then accessed in your Python code using `os.environ`.

The contents of these files should be in the following format:

```env
FOO="BAR"
OTHER_VARIABLE="FOOBAR"
```

You can use this with [agenix](https://github.com/ryantm/agenix) to expose
additional secrets to your application:

```nix
{
  age.secrets.mysite = {
    file = ../secrets/mysite.age;
    owner = "mysite_prod";
  };

  django.sites.mysite_prod = {
    # …
    extraEnvFiles = [ config.age.secrets.mysite.path ];
  }
```

### `disableACME`

Default value: `false`

Set this to `true` to use self-signed certificates instead of requesting them
through ACME. Very useful for testing!

### `manageScript`

Read-only

This option will contain a derivation that allows you to run Django management
commands. To invoke it, use
`${config.django.sites.my_site.manageScript}/bin/manage-my_site`. For example,
to create a systemd timer that runs a Django management command every minute:

``` nix
  systemd.timers.mysite-clean-expired-orders = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "60s";
      OnUnitInactiveSec = "60s";
      Unit = "mysite-clean-expired-orders.service";
    };
  };

  systemd.services.mysite-clean-expired-orders = {
    serviceConfig.Type = "oneshot";
    serviceConfig.User = config.django.sites.my_site.user;
    script = "${config.django.sites.my_site.manageScript}/bin/manage-my_site clean_orders";
  };
```

### `user`

Default value: name of the site instance

The user to run gunicorn and the manage script as. It will be automatically
created.

### `group`

Default value: name of the site instance

The group to run gunicorn and the manage script as. It will be automatically
created.
