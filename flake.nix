{
  description = "nix-gleam - nix builder for gleam applications";

  outputs = {
    self,
  }: {
    overlays.default = import ./overlay.nix;
  };
}
