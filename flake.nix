{
  description = "nix-gleam - nix builder for gleam applications";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      forEachPkgs =
        f:
        lib.genAttrs lib.systems.flakeExposed (
          system:
          f (
            import nixpkgs {
              localSystem.system = system;
              overlays = [ self.overlays.default ];
            }
          )
        );
    in
    {
      packages = forEachPkgs (pkgs: {
        inherit (pkgs) buildGleamApplication;
      });

      overlays.default = import ./overlay.nix;

      checks = forEachPkgs (
        pkgs: lib.filterAttrs (_: d: lib.isDerivation d) (pkgs.callPackage ./tests { })
      );
    };
}
