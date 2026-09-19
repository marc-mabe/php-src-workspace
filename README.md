# php-src workspace

Docker + Lima testing environments for php-src, kept outside the php-src tree
itself. The php-src checkout lives here as the `php-src` git submodule, so this
tooling can be versioned without touching upstream.

```
php-src-workspace/
├── bin/            # host + container helper scripts
├── Dockerfile*     # dev images
├── lima.yaml       # Lima VM definition
└── php-src/        # submodule: git@github.com:marc-mabe/php-src.git
```

Clone with the submodule:

```shell
git clone --recurse-submodules git@github.com:marc-mabe/php-src-workspace.git
# or, in an existing clone:
git submodule update --init
```

Builds land in `php-src/build/<arch>`, which is untracked content in the
submodule. `info/exclude` is never cloned, so recreate it to keep `git status`
there quiet. A submodule's `.git` is a file pointing into `.git/modules/`, so
ask git for the path rather than assuming `php-src/.git/info/`:

```shell
printf '/build/arm64/\n/build/amd64/\n/build/arm32/\n/build/i386/\n' \
    >> "$(git -C php-src rev-parse --path-format=absolute --git-path info/exclude)"
```

Run php-src builds and tests in isolated containers for four architectures:

| Container | Platform       | Use case              |
|-----------|----------------|-----------------------|
| `arm64`   | `linux/arm64`  | 64-bit ARM (aarch64)  |
| `amd64`   | `linux/amd64`  | 64-bit x86_64         |
| `arm32`   | `linux/arm/v7` | 32-bit ARM (armv7l)   |
| `i386`    | `linux/amd64` + multilib | 32-bit i386 (via `-m32`) |

Containers mount the `php-src` submodule at `/php-src` (the working directory)
and this workspace at `/workspace`, so you can edit on the host and build inside
the container.

## Prerequisites

The scripts pick a backend from the host OS; `PHP_SRC_BACKEND` overrides it.

**Linux** (`native`):

- Docker Engine, with the buildx plugin (`docker-buildx-plugin`)

**macOS** (`lima`) -- a Lima VM provides the Linux kernel:

- [Lima](https://lima-vm.io/docs/installation/) 2.0+

Any architecture the host cannot execute itself has to be emulated, by Rosetta
or by QEMU. Under `lima` everything needed for that is already in the VM, set up
by `bin/setup.sh`. Under `native` the QEMU binfmt handlers live on the host, so
`bin/setup.sh` registers them there.

## Architecture notes

Which containers run natively and which are emulated depends on the host:

| Container | Apple Silicon | Intel Mac | Linux x86_64 | Linux arm64 |
|-----------|---------------|-----------|--------------|-------------|
| `arm64`   | native        | QEMU      | QEMU         | native      |
| `amd64`   | Rosetta, else QEMU | native | native    | QEMU        |
| `arm32`   | QEMU          | QEMU      | QEMU         | QEMU¹      |
| `i386`    | QEMU          | QEMU      | native       | QEMU        |

- `i386` is the amd64 image with multilib (`-m32`). Rosetta translates x86_64
  only, so it never applies there; on a 64-bit x86 host the CPU runs 32-bit code
  natively. `arm32` is a real armhf image, so it needs none of that.
- ¹ An arm64 CPU *may* execute 32-bit ARM, but Apple Silicon does not, and the
  kernel advertising `CONFIG_COMPAT` makes binfmt skip `qemu-arm` as
  unnecessary. `bin/setup.sh` registers it explicitly; see Troubleshooting.
- The zip extension is disabled in the i386 image because `libzip-dev:i386` is
  not published for Ubuntu 24.04.
- Rosetta is currently broken on macOS 27.0; `bin/shell.sh` probes for it and
  falls back to QEMU. See Troubleshooting.

## Quick start

From the workspace root:

```shell
./bin/setup.sh
```

This will:

1. Create and start a Lima VM named `php-src-docker` with Docker and multi-arch support
2. Build the four development images

Open a shell in a container:

```shell
./bin/shell.sh arm64
./bin/shell.sh amd64
./bin/shell.sh i386
```

The architecture argument is optional throughout; omitting it uses the host's
and says so on stderr:

```shell
./bin/shell.sh                 # host arch
./bin/make.sh                  # host arch
./bin/configure-minimal.sh     # host arch
```

`--` separates a script's own arguments from the ones it passes on:

```shell
./bin/make.sh arm64 -- test TESTS=tests/basic
./bin/make.sh -- -n                            # host arch, `make -n`
./bin/shell.sh amd64 -- gcc --version          # everything after -- goes to the container
./bin/configure-full.sh i386 -- --enable-calendar
```

Before `--` only an architecture is accepted, so `./bin/make.sh amd46 -- test`
is an error rather than a build for the wrong target. Without `--` a leading
architecture is still recognised (`./bin/shell.sh amd64 uname -m`), and anything
else starts the pass-through arguments.

## Build and test PHP

`configure-minimal.sh` and `configure-full.sh` automatically run inside the
matching container when invoked from the host. Each configures an out-of-tree
build in `php-src/build/<arch>`, so the four architectures coexist and the
source tree stays clean:

```shell
./bin/configure-minimal.sh i386     # configures php-src/build/i386
./bin/configure-full.sh arm64       # configures php-src/build/arm64
```

`make` then runs from the build directory, not the source root. `make.sh` does
that for you:

```shell
./bin/make.sh arm64                       # make -j"$(nproc)" in build/arm64
./bin/make.sh i386 -- test TESTS=tests/basic
```

Or drive it yourself. `shell.sh` runs a single argument verbatim in the
container shell, so pipelines and `&&` work; several arguments are a command
and its arguments:

```shell
./bin/shell.sh arm64 'cd /php-src/build/arm64 && make -j"$(nproc)"'
./bin/shell.sh arm64 uname -m
```

Two things to watch with `shell.sh`:

- Its working directory is `/php-src`, the source tree, not a build directory.
  `./bin/shell.sh arm64 make` therefore finds no Makefile; use `make.sh`, or
  `cd` to `/php-src/build/<arch>` first as above.
- Quote whatever the container should expand. `&&`, `|` and `$(...)` in an
  unquoted command are interpreted by your *host* shell: `'make -j$(nproc)'`
  counts the container's CPUs, `make -j$(nproc)` counts the host's.

Override the location with `PHP_SRC_BUILD_DIR` (forwarded into the container):

```shell
PHP_SRC_BUILD_DIR=/php-src/build/arm64-nojit ./bin/configure-minimal.sh arm64 -- --disable-opcache
```

`php-src/build/` is upstream's build-system directory (`php.m4`, `shtool`,
`Makefile.global`, ...). It holds only files, so the per-arch subdirectories do
not collide with it. They are untracked content in the submodule; the clone step
at the top keeps them out of `git status`.

## Files

| File | Purpose |
|------|---------|
| `lima.yaml` | Lima VM definition (Docker + Rosetta + QEMU binfmt) |
| `Dockerfile` | Dev image for any native platform (arm64, amd64, arm32) |
| `Dockerfile.i386` | 32-bit dev image (amd64 + i386 multilib, like CI) |
| `bin/setup.sh` | Prepare the container environment and build the images |
| `bin/shell.sh` | Run a shell or command in an arch-specific container |
| `bin/configure-minimal.sh` | Minimal `./configure` (`--disable-all --enable-debug --enable-zend-test`) |
| `bin/configure-full.sh` | Full development `./configure` wrapper per architecture |
| `bin/lib.sh` | Shared shell library: arch table, paths, VM access, configure |
| `bin/make.sh` | Run make in the per-arch build directory |
| `bin/build-images.sh` | Rebuild images only |
| `php-src/` | Submodule: the php-src checkout, mounted at `/php-src` |
| `tmp/` | Scratch area, not version controlled (see below) |

## Lima VM

This section applies to the `lima` backend only; the native backend has no VM.

### Sizing

`bin/setup.sh` gives the VM every logical CPU on the host. Lima's own default is
`min(4, host cores)` and it has no "use all" setting.

On an existing VM the count is compared and, only if it differs, the VM is
stopped to change it, since the CPU count is fixed at boot. `nproc` inside the
containers then reports the full count, which is what `make.sh` uses for `-j`.

Override with `PHP_SRC_VM_CPUS`:

```shell
PHP_SRC_VM_CPUS=4 ./bin/setup.sh --no-build
```

Memory is at 8 GiB. If a wide `-j` starts swapping or the OOM killer appears,
raise `memory:` in `lima.yaml` and recreate the VM, or lower `PHP_SRC_VM_CPUS`.

### Instance management

```shell
limactl stop php-src-docker
limactl start php-src-docker
limactl delete php-src-docker   # remove VM
```

After a VM reboot, re-run `./bin/setup.sh --no-build` to restore
QEMU binfmt handlers.

Use a different instance name:

```shell
LIMA_INSTANCE=my-php limactl start --name=my-php lima.yaml
LIMA_INSTANCE=my-php ./bin/setup.sh --no-build
```

## Scratch area

`tmp/` is the workspace's scratch directory. It holds the throwaway artefacts of
an investigation -- probe programs, one-off benchmarks and repro scripts, build
and test logs, captured output to diff between architectures.

It is listed in `.gitignore`, so nothing in it is committed and you can delete
the whole directory at any time without losing anything the workspace needs.
Keep the repository root for the container tooling itself; anything written to
answer one question belongs here.

`tmp/` is also excluded from the Docker build context via `.dockerignore`, so
its size does not slow image builds. Inside a container it is reachable at
`/workspace/tmp`.

## Troubleshooting

**`Read-only file system` during buildconf/configure**

The Lima home directory mount must be writable. Recreate the VM with the
current `lima.yaml` (which sets `writable: true`), or run:

```shell
limactl stop php-src-docker
limactl start php-src-docker --mount-writable
```

**`assertion failed [sw_reserved_ptr->magic1 == kFpXstateMagic1]` / `rt_sigreturn`**

A Rosetta bug, not a problem with your command. Rosetta aborts on signal return
as soon as the translated guest does anything non-trivial. Observed on macOS
27.0 (build 26A428) on a freshly created VM: 8/8 failures compiling and running
a one-line C program under Rosetta, 0/10 under QEMU, arm64 unaffected.

This affects amd64 only; i386 always uses QEMU regardless.

`bin/shell.sh` probes Rosetta on first use per Lima instance and macOS build,
caches the verdict in `~/.cache/php-src-workspace/rosetta-<instance>-<build>`,
and falls back to QEMU when it is broken. QEMU is considerably slower but
correct. An OS update changes the cache key, so Rosetta is re-probed
automatically; delete the cache file to force it sooner.

```shell
PHP_SRC_ROSETTA=1 ./bin/shell.sh amd64 ...   # force Rosetta (amd64 only)
PHP_SRC_ROSETTA=0 ./bin/shell.sh amd64 ...   # force QEMU
```

**`No rule to make target '/php-src/build-amd64/...'` after moving a build directory**

Autoconf bakes absolute paths into `Makefile`, `config.status` and `libtool`, so
a build directory cannot be relocated. Delete it and re-run the configure
script.

**`exec format error` when running amd64 or i386 containers on Apple Silicon**

Ensure Docker CDI is enabled and `containerd-snapshotter` is disabled in the
Lima VM (setup.sh does this automatically):

```shell
./bin/setup.sh --no-build
```

For amd64 containers, the scripts pass `--device=lima-vm.io/rosetta=cached`.

**`exec format error` when running a foreign-arch container**

Re-register the binfmt handlers. They live wherever the docker daemon does, so
under `lima` that is inside the VM:

```shell
limactl shell php-src-docker -- docker run --privileged --rm tonistiigi/binfmt --install all
```

and under `native` on the host itself:

```shell
docker run --privileged --rm tonistiigi/binfmt --install all
```

`./bin/setup.sh --no-build` does this for you on either backend.

**32-bit ARM fails with `exec format error`**

`qemu-arm` is missing. On an arm64 host the kernel is built with
`CONFIG_COMPAT`, so it claims AArch32 support and binfmt installers skip the
handler as unnecessary -- but Apple Silicon does not implement AArch32 at EL0,
so nothing can run the binaries. `bin/setup.sh` registers the handler directly
against the VM's `/usr/bin/qemu-arm`.

The docker daemon caches its supported platforms at startup, so registering a
handler while it is running has no effect until it restarts. `bin/setup.sh`
restarts it as its next step; if you register one by hand, restart the daemon
afterwards.

**Bind mount is empty inside the container**

Ensure this workspace lives under your home directory (Lima mounts `$HOME` into
the VM by default), or add a custom mount when starting Lima. Also check that the
`php-src` submodule is initialised (`git submodule update --init`) — an empty
submodule directory gives an empty `/php-src`.

**Slow i386 builds**

32-bit emulation on non-i386 hosts is expected to be slow. Prefer running i386
workloads on an amd64 host when possible.
