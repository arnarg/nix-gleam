{
  description = "nix-gleam - nix builder for gleam applications";

  inputs.nixpkgs = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      forEachPkgs = f: lib.genAttrs lib.systems.flakeExposed (system: f nixpkgs.legacyPackage.${system});
    in
    {
      packages = forEachPkgs (pkgs: pkgs.callPackage ./builder { });
      overlays.default = import ./overlay.nix;
    };
}
