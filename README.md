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
      # The derivation containing your Python environment as a 
      # `dependencyEnv` attribute (see the docs of the `package` option below
      # for details)
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

## Options

### `package`

**Mandatory**

Derivation that contains your Django project.

The derivation is expected to have a `dependencyEnv` passthru attribute, which
should be the Python environment with all dependencies. If you’re using
[poetry2nix](https://github.com/nix-community/poetry2nix),
this is automatically added by [mkPoetryApplication](https://github.com/nix-community/poetry2nix#mkPoetryApplication).

### `staticFilesPackage`

**Mandatory**

Derivation that contains your project static files. Usually the result of
`collectstatic`. You can create this derivation from your site derivation with
something like this:

``` nix
staticFilesPackage = stdenv.mkDerivation {
  pname = "${package.pname}-static";
  version = package.version;
  src = ./.;
  buildPhase = ''
    export STATIC_ROOT=$out
    export DJANGO_SETTINGS_MODULE=mysite.config.settings.base
    export MEDIA_ROOT=/dev/null
    export SECRET_KEY=dummy
    export DATABASE_URL=sqlite://:memory:
    ${package.dependencyEnv}/bin/django-admin collectstatic --noinput
  '';
  phases = [ "buildPhase" ];
};
```

Feel free to adapt this if you use external assets builders such as Webpack.

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
