{
  description = "The Marlowe language";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";

    haskellNix.url = "github:input-output-hk/haskell.nix";

    nixpkgs.follows = "haskellNix/nixpkgs-unstable";

    isabelle-nixpkgs.url = "nixpkgs/nixos-22.05";

    tullia.url = "github:input-output-hk/tullia";

    nixLsp.url = "github:oxalica/nil";
  };


  outputs = { self, flake-utils, nixpkgs, haskellNix, isabelle-nixpkgs, tullia, nixLsp }:
    let
      inherit (flake-utils.lib) eachSystem system;

      supportedSystems = [ system.x86_64-linux system.x86_64-darwin ];

      base = { evalSystem ? null }: eachSystem supportedSystems (system:
        let evalSystem' = if evalSystem == null then system else evalSystem; in
        let
          evalSystem = evalSystem';

          overlays = [ haskellNix.overlay nixLsp.overlays.nil];

          pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };

          isabelle-pkgs = isabelle-nixpkgs.legacyPackages.${system};

          writeShellScriptBinInRepoRoot = name: script: pkgs.writeShellScriptBin name ''
            cd `${pkgs.git}/bin/git rev-parse --show-toplevel`
            ${script}
          '';
          build-marlowe-proofs = writeShellScriptBinInRepoRoot "build-marlowe-proofs" ''
            #!/bin/bash
            echo "Building Marlowe proofs"

            # We build hold library (with -b) so that is available in
            # the users HEAP directory for fast rebuilds. In a user
            # machine it only builds the first time, the next time it
            # will see that there are no changes.

            if [ "$1" != "false" ]; then
              echo "Building HOL-Library"
              isabelle build -v -b HOL-Library
            fi

            # We clean the generated files to avoid orphans
            rm -Rf isabelle/generated

            # We build the different sessions that conform the Marlowe specification
            isabelle build -v -b -d isabelle Util
            isabelle build -v -b -d isabelle Core
            isabelle build -v -b -d isabelle Examples
            isabelle build -v -b -e -d isabelle CodeExports
            isabelle build -v -b -d isabelle StaticAnalysis
          '';

          build-marlowe-docs = writeShellScriptBinInRepoRoot "build-marlowe-docs" ''
            echo "Generating Literate Haskell Tex"
            lhs2TeX isabelle/haskell/MarloweCoreJson.lhs | sed '1,/PATTERN FOR SED/d' > isabelle/Doc/Specification/document/marlowe-core-json.tex

            echo "Building Marlowe docs"
            isabelle document -v -V -d isabelle -P papers Cheatsheet
            isabelle document -v -V -d isabelle -P papers Specification
          '';

          edit-marlowe-proofs = writeShellScriptBinInRepoRoot "edit-marlowe-proofs" ''
            cd isabelle
            isabelle jedit -d . -u Doc/Specification/Specification.thy
          '';

          latex = (pkgs.texlive.combine {
            inherit (pkgs.texlive) scheme-basic ulem collection-fontsrecommended mathpartir stmaryrd polytable lazylist;
          });

          tulliaPackage = tullia.packages.${system}.default;

          project = pkgs.haskell-nix.cabalProject' {
            src = ./.;
            compiler-nix-name = "ghc924";
            inherit evalSystem;
            shell.tools.cabal = { inherit evalSystem; };
            shell.tools.haskell-language-server = { inherit evalSystem; };
            shell.inputsFrom = [ packages.isabelle-test ];
            shell.nativeBuildInputs =
              ( with scripts; [
                  build-marlowe-proofs
                  edit-marlowe-proofs
                  build-marlowe-docs
              ]
              ) ++
              [ latex pkgs.haskellPackages.lhs2tex tulliaPackage pkgs.nil];
          };

          flake = project.flake { };

          tests = import ./nix/tests {
            src = ./.;
            inherit pkgs  isabelle-pkgs scripts latex;
          };
          packages = flake.packages // {
            inherit (tests) isabelle-test;
          };
        in
        flake // {
          inherit packages;
          hydraJobs = packages;
          ciJobs = packages;
        } // tullia.fromSimple system (import ./nix/tullia.nix self system)
      );
      hydraSystem = "x86_64-linux";
      pkgsHydra = nixpkgs.legacyPackages.${hydraSystem};
      baseHydra = base { evalSystem = hydraSystem; };
    in
    base { } // {
      hydraJobs = baseHydra.hydraJobs // {
        forceNewEval = pkgsHydra.writeText "forceNewEval" (self.rev or self.lastModified);
        required = pkgsHydra.releaseTools.aggregate {
          name = "marlowe";
          constituents = builtins.concatMap (system: map (x: "${x}.${system}") (builtins.attrNames baseHydra.hydraJobs)) supportedSystems;
        };
      };
    };

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    allow-import-from-derivation = true;
    accept-flake-config = true;
  };
}
