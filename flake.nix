{
  description = "DankMaterialShell bar pill showing instantaneous network bandwidth (RX/TX), read from /proc/net/dev.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        # The plugin is just two text files. The derivation copies them
        # into the layout DMS's plugin loader expects (a directory whose
        # name becomes the plugin id at install time, containing
        # plugin.json + the referenced .qml component). Consumers wire it
        # up via `programs.dank-material-shell.plugins.<name>.src = …`.
        packages.default = pkgs.runCommand "dms-bandwidth-pill" {} ''
          mkdir -p $out
          cp ${./plugin.json} $out/plugin.json
          cp ${./BandwidthWidget.qml} $out/BandwidthWidget.qml
        '';

        # Convenience for `nix flake check`; pure-data plugin so there's
        # not much to test, but we at least confirm the JSON parses.
        checks.plugin-json-valid = pkgs.runCommand "plugin-json-valid" {} ''
          ${pkgs.jq}/bin/jq -e '.id and .name and .component' ${./plugin.json} > /dev/null
          touch $out
        '';
      }
    );
}
