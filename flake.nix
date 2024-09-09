{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    zig.url = "github:mitchellh/zig-overlay";
    zig.inputs.nixpkgs.follows = "nixpkgs";

    zls.url = "github:zigtools/zls";
    zls.inputs.nixpkgs.follows = "nixpkgs";
    zls.inputs.zig-overlay.follows = "zig";
  };

  outputs = { self, zig, zls, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      zlsOverlay = (final: prev: {
        zlspkgs = zls.packages.${system};
      });
      pkgs = import nixpkgs {
        system = system;
        overlays = [
          zig.overlays.default
          zlsOverlay
        ];
      };
    in
      {
        devShells.${system}.default =
          pkgs.mkShellNoCC {
            packages = with pkgs; [
              R
              zigpkgs.master
              # zlspkgs.zls
            ];
          };
      };
}
