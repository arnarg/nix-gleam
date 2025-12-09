{
  description = "nix-gleam - nix builder for gleam applications";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      forEachPkgs = f: lib.genAttrs lib.systems.flakeExposed (system: f nixpkgs.legacyPackages.${system});
    in
    {
      legacyPackages = forEachPkgs (pkgs:
        let builder = pkgs.callPackage ./builder { };
        in { inherit (builder) buildGleamApplication; }
      );
      overlays.default = import ./overlay.nix;
    };
}
