{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShellNoCC {

  LOCALE_ARCHIVE = if pkgs.stdenv.isLinux then "${pkgs.glibcLocales}/lib/locale/locale-archive" else "";

  packages = with pkgs; [
    zig
    R
  ];
}
