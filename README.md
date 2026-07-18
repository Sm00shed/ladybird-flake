# Ladybird Nix development environment

A Nix flake that provides a `nix develop` shell for building the
[Ladybird](https://github.com/LadybirdBrowser/ladybird) browser. The shell
supplies a pinned toolchain and every build dependency from the Nix store, so
Ladybird's own dependency fetcher is never used.

Tested scope: on Linux x86_64 (NixOS and CachyOS) the browser builds and runs.
On macOS x86_64 it builds, but runtime testing is limited. Apple Silicon is
untested.

The default source is the last tested Ladybird commit tracked in
`versions.json`. Run `lb list` to see all tested versions.

## Requirements

The only thing that must be installed on the host is Nix. No compiler, no
CMake, no git — the shell brings its own Clang 21, LLD, CMake, Ninja, git, and
the rest of the build inputs.

### Install Nix

On any Linux distribution or macOS (not needed on NixOS), install Nix with the
official installer:

```bash
sh <(curl -L https://nixos.org/nix/install)
```

### Enable flakes

Enable flakes once so they stay on. Add this line to `~/.config/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

On NixOS, set it in `configuration.nix` instead and run `nixos-rebuild switch`:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

After this, `nix develop github:Sm00shed/ladybird-flake` works directly.

## Quick start

Clone Ladybird, enter the shell, configure, and build:

```bash
git clone https://github.com/LadybirdBrowser/ladybird.git
cd ladybird
```

Then enter the shell (this opens an interactive subshell):

```bash
nix develop github:Sm00shed/ladybird-flake
```

The shell prints its banner and is ready. Configure the build with CMake:

```bash
cmake -B Build/release -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_LTO_FOR_RELEASE=OFF \
  -DICU_ROOT="$ICU_ROOT" \
  -DENABLE_NETWORK_DOWNLOADS=OFF \
  -DLADYBIRD_CACHE_DIR=Caches
```

On macOS, add the deployment target so the build matches the SDK:

```bash
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
```

Compile:

```bash
ninja -j$(nproc) -C Build/release
```

## Build configuration

The CMake options above serve these purposes.

`-DCMAKE_BUILD_TYPE=Release`
  Optimized build.

`-DENABLE_LTO_FOR_RELEASE=OFF`
  Disables link-time optimization to keep link times and memory use down.

`-DICU_ROOT="$ICU_ROOT"`
  Points CMake at the ICU 78 development tree from the store. The shell exports
  `ICU_ROOT`.

`-DENABLE_NETWORK_DOWNLOADS=OFF`
  Stops the build from fetching data files at configure time. The shell
  pre-populates them (see below).

`-DLADYBIRD_CACHE_DIR=Caches`
  Uses the in-tree `Caches` directory that the shell fills.

`-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"`
  macOS only. Aligns the deployment target with apple-sdk_15. Without it the
  build falls back to an older target and fails.

## Running

After the build, launch the browser from the shell:

```bash
Ladybird
```

`Ladybird` is a shell function that hides the platform differences. On Linux it
runs `Build/release/bin/Ladybird`. On macOS it runs the `Ladybird.app` bundle
with `--disable-sandbox`, because the sandbox needs codesigning. In both cases
the CA certificate is passed automatically. Override it with an environment
variable:

```bash
LADYBIRD_CERTIFICATE=/path/to/cert.crt Ladybird
```

## Source version management

The `lb` command is available inside the shell and selects which Ladybird
commit the shell builds. The active version is printed each time the shell
starts:

    Ladybird Dev Shell
       Source: 94a55b0e (2026-07-18)
       Env:    nixpkgs 8f0500b9

`lb list`
  Show all tested versions from `versions.json`.

`lb use <date|hash>`
  Re-enter the shell on a specific tested version by date, or on any commit by
  hash.

`lb new`
  Re-enter the shell on the current upstream HEAD. Untested until confirmed.

`lb ok`
  Record the running version in `versions.json` and push it to the history.
  Maintainer only.

When filing a bug, include the source hash printed at startup.

`lb` overrides only the Ladybird source. To pin the whole flake instead —
toolchain and dependencies included — append the commit hash to the flake
reference:

```bash
nix develop github:Sm00shed/ladybird-flake/<commit-hash>
```

`lb ok` is maintainer-only and needs a local clone of this flake next to the
Ladybird source:

    ~/ladybird/
    ~/ladybird-flake/

Point `lb` at it with `LADYBIRD_FLAKE_DIR=~/ladybird-flake` if it lives
elsewhere.

## What this environment does

The shell replaces Ladybird's vendored dependency handling. Ladybird normally
uses vcpkg to fetch and build third-party libraries; here every library comes
from the Nix store instead.

The shell unsets `VCPKG_ROOT` and `CMAKE_TOOLCHAIN_FILE` so the build ignores
vcpkg entirely.

It sets `CMAKE_PREFIX_PATH` to the store paths of each dependency, so CMake
never reads `/usr/lib` or other system locations.

Several dependencies need overrides:

- **skia** is pinned to the exact revision Ladybird expects and built with an
  extra flag that gives `SKCMS_API` default symbol visibility, which the link
  step requires.
- **angle** is used on Linux for the GPU backend. It is built with the Clang 20
  standard environment because Clang 21 hits an internal compiler error while
  parsing a nested union type in ANGLE's Vulkan helpers.
- **mimalloc** is pinned to 2.2.7. Ladybird targets the mimalloc 2.x series;
  the nixpkgs default is a 3.x release, which is incompatible.
- **libtommath** is patched so that `mp_set_double` is compiled in. Apple Clang
  does not define `__STDC_IEC_559__` even on x86_64, which is IEEE-754
  compliant, so the function would otherwise be dropped. The patch forces the
  guard on.

The shell also exports environment used by the build, and pre-populates data
caches:

- `ICU_ROOT` points at the ICU 78 development tree, matching the `-DICU_ROOT`
  CMake option.
- `FONTCONFIG_FILE` points at a generated fontconfig file that exposes the
  DejaVu and Liberation font packages, so text rendering works without any
  host font configuration.
- The `Caches` directory is filled with the data files Ladybird would otherwise
  download: the Unicode Character Database (UCD, including emoji and IDNA
  tables), the HSTS preload list, the Public Suffix List, and the CA
  certificate bundle (CACERT). The CA bundle is copied into the tree rather
  than referenced in the store because the Linux Landlock sandbox blocks
  RequestServer from reading store paths directly.

## Known upstream issues

Two Ladybird bugs surface on macOS and are worked around by the shell. Both are
reported upstream.

- A deprecated Core Video call sits outside its diagnostic-suppression block in
  `VSyncScheduler.cpp`. The shell adds `-Wno-deprecated-declarations`.
  <https://github.com/LadybirdBrowser/ladybird/issues/10657>
- A lambda in `TabController.mm` has no explicit return type. On x86_64 macOS,
  `BOOL` is a signed char, so return-type deduction cannot reconcile `bool` and
  `BOOL`. This is a hard error that no warning flag suppresses, so the shell
  patches in an explicit `-> bool`.
  <https://github.com/LadybirdBrowser/ladybird/issues/10658>

## Platform notes

On Linux the environment uses the standard `nixos-26.05` nixpkgs, so all inputs
come from the binary cache with no local rebuilds. The Linux-only inputs (Qt,
Vulkan, PulseAudio, libdrm, glslang) are present in the shell, but not all code
paths that use them have been exercised.

On macOS the build needs apple-sdk_15, because Ladybird references a macOS 15
API. apple-sdk_15 requires a deployment target of 15.4 or later, but the
nixpkgs default is lower.

To fix this the flake pulls Darwin packages from a nixpkgs fork
(`Sm00shed/nixpkgs`, branch `darwin-min-version-15-4`) that sets
`darwinMinVersion = "15.4"`. This aligns the deployment target with the SDK and
avoids build failures in gnulib-based packages that depend on `strchrnul`
availability.

macOS 15.4 or later is therefore required.

## Acknowledgements

This environment started as the Ladybird shell from
nix-community/nix-environments (MIT). It has since been rewritten,
but the original made it possible. Thanks to its authors.

Original: https://github.com/nix-community/nix-environments/tree/master/envs/ladybird

## License

GPL-2.0, see LICENSE.
Originally derived from nix-community/nix-environments (MIT), see LICENSE.MIT.
