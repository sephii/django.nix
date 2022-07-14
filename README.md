# django.nix: easy Django deployment on NixOS

Project status: **experimental** (don’t expect up-to-date docs, and expect bugs and missing features)

## What is it?

django.nix is a NixOS module that allows you to easily deploy Django websites. Use it like this (in your `configuration.nix`):

``` nix
{
  django.sites = {
    mysite_staging = {
      pkg = pkgs.mysite;
      hostname = "staging.mysite.com";
      settingsModule = "mysite.config.settings.staging";
    };
  };
}
```

This will:

* Create a system user for the site
* Generate a secret key
* Run the `migrate` command on activation
* Set up a gunicorn service (named `gunicorn-{your_site_name}`)
* Create a `manage-{your_site_name}` to easily run management commands
* Make sure Postgresql is installed and that a database with the site name exists
* Create a Caddy configuration with automatic HTTPS

You should make sure your derivation (`pkgs.mysite`) contains the `gunicorn` and `gevent` packages.

## Options

TODO (check `django.nix` in the meantime)
