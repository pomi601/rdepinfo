{
  description = "Apply additional patches to R via an overlay";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      ROverlay = (final: prev: {
        R = prev.R.overrideAttrs (finalAttrs: prevAttrs: {
          patches = prevAttrs.patches ++ [ ./available-packages.patch ];
        });
      });

      pkgs = import nixpkgs {
        system = system;
        overlays = [
          ROverlay
        ];
      };
    in
      {
        devShells.${system}.default =
          pkgs.mkShell {
            packages = with pkgs; [
              R
            ];

            LOCALE_ARCHIVE = if pkgs.stdenv.isLinux then "${pkgs.glibcLocales}/lib/locale/locale-archive" else "";
          };
      };
}
