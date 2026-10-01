{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/26.05";

  outputs =
    { nixpkgs, ... }:
    {
      devShells = builtins.mapAttrs (
        system: pkgs:

        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              zig
              zls
            ];
          };
        }) nixpkgs.legacyPackages;

      formatter = builtins.mapAttrs (_: pkgs: pkgs.nixfmt-tree) nixpkgs.legacyPackages;
    };
}
