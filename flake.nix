{
  outputs = { self, nixpkgs }: {
    nixosModules.djangonix = import ./django.nix;
  };
}
