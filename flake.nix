{
  description = "A Nix flake for SafeHaven dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};

        # NodeJS environment
        fixedNode = pkgs.nodejs_24;

        playwright_flake_version = pkgs.playwright.version;

        playwright_npm_version = (pkgs.lib.importJSON (frontend/package-lock.json))
          .packages
          ."node_modules/@playwright/test"
          .version;

        checkPlaywrightVersion = pkgs.writeShellScriptBin "check_playwright_version" ''
          set -e

          if [ "${playwright_flake_version}" = "${playwright_npm_version}" ]; then
            echo "Using playwright ${playwright_flake_version} in both flake and npm dependencies"
          else
            echo "Using playwright ${playwright_flake_version} in flake and playwright ${playwright_npm_version} in npm dependencies"
            echo "This is an error, please fix the npm version to match the flake version in package.json"
            exit 1
          fi
        '';

        checkProject = pkgs.writeShellScriptBin "check_project" ''
          set -e
          
          pushd backend
            echo "::group::sqlx migrations checks"
              echo "Create the database"
              cargo sqlx database create

              echo "Run the migrations"
              cargo sqlx migrate run

              echo "Check the migrations"
              cargo sqlx prepare --check
            echo "::endgroup::"

            echo "::group::Backend tests"
              cargo test
            echo "::endgroup::"

            echo "::group::Backend lint"
              cargo fmt -- --check
              cargo clippy -- -D warnings
            echo "::endgroup::"

            echo "::group::OpenAPI sync checks"
              cargo run -- openapi ../frontend/calc-openapi.json
              if ! diff ../frontend/calc-openapi.json ../frontend/openapi.json; then
                echo "OpenAPI has changed, please run 'cargo run -- openapi ../frontend/openapi.json' in the frontend"
                exit 1
              fi
              rm ../frontend/calc-openapi.json
            echo "::endgroup::"
          popd

          pushd frontend
            echo "::group::Frontend checks"
              check_playwright_version

              npm ci
              npm run generate-api
              npm run lint
              npm run build
              npm run test
            echo "::endgroup::"
          popd
        '';

        regenApi = pkgs.writeShellScriptBin "regen_api" ''
          set -e

          pushd backend
            cargo run -- openapi ../frontend/openapi.json
          popd

          pushd frontend
            npm run generate-api
          popd
        '';

        nginxConfigFile = pkgs.writeText "" ''
          daemon off;
          error_log stderr info;
          pid /tmp/nginx.pid;

          worker_processes auto;

          events {
            worker_connections 1024;
          }

          http {
            default_type application/octet-stream;

            sendfile on;
            keepalive_timeout 65;

            access_log /dev/stdout;

            server {
              listen 4000;

              location / {
                proxy_pass http://localhost:3000;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;

                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection "upgrade";
              }

              location /api {
                proxy_pass http://localhost:28669;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              }
            }
          }
        '';

        processConfigFile = let
          processes = {
            backend = {
              command = "cargo run -- serve";
              working_dir = "./backend";
            };
            frontend = {
              command = "npm run dev";
              working_dir = "./frontend";
            };
            reverse = {
              command = "${pkgs.nginx}/bin/nginx -c ${nginxConfigFile}";
            };
          };
        in
          pkgs.writeText "process.yaml" (builtins.toJSON {
            version = "0.5";
            processes = processes;
          });

        pgHba = pkgs.writeText "pg_hba.conf" ''
          local all all trust
          host all all 0.0.0.0/0 trust
          host all all ::/0 trust
        '';

        pgInitScript = pkgs.writeTextFile {
          name = "pg_init_script";
          text = ''
            #!/bin/sh
            set -e
            # Copy the pg_hba.conf file
            cp /wanted_pg_hba.conf /var/lib/postgresql/data/pg_hba.conf
            # Create the database
            psql -U postgres -c "CREATE DATABASE safehaven;"
            psql -U postgres -d safehaven -c "CREATE EXTENSION postgis;"
          '';
          executable = true;
        };

        startDockerPostgresql = pkgs.writeShellScriptBin "start_docker_postgresql" ''
          set -e
          docker run --rm -d \
            --name safehaven-postgres \
            -e POSTGRES_PASSWORD=postgres \
            -v $PWD/.pgdata:/var/lib/postgresql/data \
            -v ${pgHba}:/wanted_pg_hba.conf \
            -v ${pgInitScript}:/docker-entrypoint-initdb.d/init.sh \
            -p 5432:5432 \
            postgis/postgis:16-3.4-alpine
        '';

        startDevEnv = pkgs.writeShellScriptBin "start_dev_env" ''
          set -e
          ${pkgs.process-compose}/bin/process-compose -f ${processConfigFile}
        '';

        # Version when compiling the packages
        version = builtins.readFile ./container_release;

        # Backend derivation
        backend = pkgs.rustPlatform
          .buildRustPackage {
          inherit version;

          name = "safehaven-backend";
          src = ./backend;

          # When modifying cargo dependencies, replace the hash with pkgs.lib.fakeHash
          # then run `nix build .#backend`. Use the hash in the error to replace the value.
          cargoHash = "sha256-ffaFgV5i4T0miX3k2uTiAU5P+zT7EHvXax9foZXTibQ=";
        };

        # Frontend derivation
        frontend = pkgs.buildNpmPackage {
          inherit version;

          name = "safehaven-frontend";
          src = ./frontend;
          nodejs = fixedNode;

          # When modifying npm dependencies, replace the hash with pkgs.lib.fakeHash
          # then run `nix build .#frontend`. Use the hash in the error to replace the value.
          npmDepsHash = "sha256-818Wbh3ix7BRT2w4spWSMtxxhjLJr3WLHEB3MsCBo9I=";

          installPhase = ''
            runHook preInstall
            mkdir -p $out/usr/share/safehaven/static
            cp -rv dist/* $out/usr/share/safehaven/static
            runHook postInstall
          '';
        };

        # Docker image
        dockerImage = pkgs.dockerTools.streamLayeredImage {
          name = "ghcr.io/fransgenre/carte";
          tag = version;
          contents = [
            backend
            frontend
          ];
          config = {
            Cmd = ["/bin/safehaven" "serve"];
            Env = [
              "SH__SERVE_PUBLIC_PATH=/usr/share/safehaven/static"
            ];
            ExposedPorts = {"28669/tcp" = {};};
          };
        };
      in
        with pkgs; {
          packages = {inherit backend frontend dockerImage;};
          devShells.default = mkShell {
            buildInputs = [
              # Rust toolchain
              rustc
              cargo
              rustfmt
              clippy
              # Various scripts
              checkPlaywrightVersion
              checkProject
              regenApi
              startDevEnv
              startDockerPostgresql
              # Backend
              sqlx-cli
              # Front
              fixedNode
              # Nix formatting
              alejandra
              # Process composing
              process-compose
              # PostgreSQL and PostGIS
              (postgresql_16.withPackages (p: with p; [postgis]))
              # Playwright browsers for E2E
              playwright-driver.browsers
            ];
            DATABASE_URL = "postgres://postgres:postgres@localhost:5432/safehaven";
            PLAYWRIGHT_BROWSERS_PATH = "${playwright-driver.browsers}";
            PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
          };
        }
    );
}
