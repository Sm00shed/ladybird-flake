# Ladybird Nix Dev Shell

> **Work in progress. Proof of concept stage.**

Cross-distro development environment for [Ladybird](https://github.com/LadybirdBrowser/ladybird) using `nix develop`. Works on any Linux distribution (CachyOS, Ubuntu, Manjaro, Fedora, NixOS) and macOS without modifying the host system.

## Requirements

- [Nix](https://nixos.org/download/) with flakes enabled

## Install Nix

```bash
curl -L https://nixos.org/nix/install -o install-nix.sh
sh install-nix.sh
```

Restart your shell, then verify and enable flakes:

```bash
exec $SHELL
which nix
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

## Build Ladybird

**1. Clone Ladybird**
```bash
git clone https://github.com/LadybirdBrowser/ladybird.git
cd ladybird
```

**2. Enter the dev shell**
```bash
nix develop github:Sm00shed/ladybird-flake
```

**3. Configure**
```bash
cmake -B Build/release -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_LTO_FOR_RELEASE=OFF \
  -DICU_ROOT="$ICU_ROOT" \
  -DVCPKG_MANIFEST_MODE=OFF \
  -DENABLE_NETWORK_DOWNLOADS=OFF \
  -DLADYBIRD_CACHE_DIR=Caches
```

**4. Compile**
```bash
ninja -j$(nproc) -C Build/release
```

**5. Run**
```bash
./Build/release/bin/Ladybird
```

> Run Ladybird from within the `nix develop` shell.

## What this flake provides

- Clang 21 (explicit, never system compiler or Apple-Clang)
- All dependencies pinned via `flake.lock`
- `CMAKE_PREFIX_PATH` set to Nix store paths — cmake never reads `/usr/lib`
- Unicode and Public Suffix List data pre-populated (no network downloads during build)
- `$CLANGD_PATH` exported for VSCode integration
