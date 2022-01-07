# django.nix: easy Django deployment on NixOS

Project status: **experimental** (don’t expect up-to-date docs, and expect bugs and lots of missing features)

## What is it?

django.nix is a NixOS module that allows you to easily deploy Django websites. You use it like this (in your `configuration.nix`):

``` nix
{
  django.sites = {
    mysite_staging = {
      pkg = pkgs.mysite;
      hostnames = [ "staging.mysite.com"];
      settingsModule = "mysite.config.settings.staging";
    };
  };
}
```

The module:

* Creates a system user for the site
* Generates a secret key
* Runs the `collectstatic` and `migrate` commands on activation
* Sets up a gunicorn service (named `gunicorn-{your_site_name}`)
* Creates a `manage-{your_site_name}` to easily run management commands
* Makes sure Postgresql is installed and that a database with the site name exists
* Creates a Caddy configuration with automatic HTTPS

## Options

TODO (check `django.nix` in the meantime)
