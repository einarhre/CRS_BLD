# CRS_BLD

CRS_BLD is a small build environment for creating MinGW-w64 cross-compilers and Windows dependency packages from Linux or macOS.

It is used to build Windows versions of applications such as tindajudoshiai.

This system is based on ideas and build structure from MXE: <https://mxe.cc/>

The generated compiler trees and package installation directories are intentionally not tracked in Git. They are built locally from the scripts, package configuration files and patches in this repository.

## Main scripts

* `make_cross-compiler.sh`
  Builds the MinGW-w64 cross-compilers used to build Windows applications from Linux. It also builds Windows-native GCC compiler packages for the supported targets.

* `make_pkgs.sh`
  Cross-compiles third-party packages from source for use by Windows applications.

* `order_of_compilation.txt`
  Lists the intended package build order.

## Support files

* `etc/common.sh`
  Shared shell functions used by the build scripts.

* `etc/diagnostics.sh`
  Diagnostic helper script for checking the generated CRS build environment.

## Source tree

The repository contains package build recipes and patches under `src/pkg/`.

```text
src/pkg/
├── cfg
│   ├── atk.sh
│   ├── brotli.sh
│   ├── bzip2.sh
│   ├── cairo.sh
│   ├── curl.sh
│   ├── glib.sh
│   ├── gtk3.sh
│   ├── libssh2.sh
│   ├── libwebsockets.sh
│   ├── openssl.sh
│   ├── pango.sh
│   └── ...
└── ptc
    ├── cairo-1-fixes.patch
    ├── glib-1-fixes.patch
    ├── gtk3-1-fixes.patch
    ├── gtk3-2-static-deps.patch
    ├── librsvg-1-fixes.patch
    ├── pango-1-static-deps.patch
    └── ...
```

The `cfg` directory contains one shell configuration file per package.

The `ptc` directory contains package patches applied during the build.

## Generated directories

The following directories are generated locally and should not be committed:

* `build/`
* `install/`
* `src/cpl/`
* `src/pkg/tar/`

Typical generated layout:

```text
.
├── build
├── etc
├── install
└── src
```

The `build/` directory contains compiler build trees and per-target completion records. These are valuable reusable artifacts, not disposable test fixtures.

The `install/` directory contains the generated cross-compilers, native Windows compilers and compiled package outputs.

The `src/cpl/` directory contains compiler sources such as Binutils, GCC and MinGW-w64.

The `src/pkg/tar/` directory contains downloaded package source archives.

## Host requirements

The build scripts require GNU command-line tools and Bash 4 or newer. The Bash version included with macOS is too old.

### Linux

On Linux, install the usual C/C++ build environment together with Bash, GNU Make, GNU Coreutils, GNU Findutils, GNU Sed, GNU Tar, Patch, Git and ZIP.

The exact package names depend on the Linux distribution.

### macOS

A previous GCC 16.1.0 build was tested on Apple Silicon. The latest completion-cache changes have been regression-tested with simulated macOS/Homebrew behavior, but have not yet been independently validated in a native macOS integration build.

First install the Xcode Command Line Tools:

```bash
xcode-select --install
```

Install [Homebrew](https://brew.sh/) and the required GNU build tools:

```bash
brew install bash coreutils findutils gnu-sed gnu-tar gpatch grep make zip
```

Install the additional tools required by compiler sources and package recipes:

```bash
brew install automake bison cmake flex gdk-pixbuf glib libtool meson pkgconf texinfo
```

The `glib` and `gdk-pixbuf` packages provide native macOS build tools used while cross-compiling GLib- and GTK-based packages for Windows. In particular, Meson must use the native `glib-compile-resources`, `glib-compile-schemas` and `gdk-pixbuf-pixdata` executables rather than Windows target executables.

The scripts automatically prefer the Homebrew versions of GNU tools when running on macOS.

Run the scripts explicitly with Homebrew Bash if the script files are not executed directly:

```bash
/opt/homebrew/bin/bash ./make_cross-compiler.sh 16.1.0
```

The `/opt/homebrew` prefix is the normal Homebrew location on Apple Silicon. Homebrew installations on Intel Macs normally use `/usr/local`.

The macOS build creates macOS-hosted cross-compilers that produce Windows binaries. It also creates native Windows compiler packages for both supported MinGW-w64 targets.

## Compiler source setup

The compiler source archives are kept locally under:

```text
src/cpl/
```

This directory is generated/local state and is intentionally not tracked in Git.

Before building the cross-compilers, place the required compiler source archives in `src/cpl/`. The build script expects archives with names like:

```text
src/cpl/binutils-2.46.0.tar.*
src/cpl/gcc-16.1.0.tar.gz
src/cpl/mingw-w64-v14.0.0.tar.*
```

The exact versions may change, but the filename patterns are important:

* `binutils-*.tar.*`
* `gcc-*.tar.gz`
* `mingw-w64-v*.tar.*`

The available GCC versions are detected from the `gcc-*.tar.gz` files in `src/cpl/`.

For example, a prepared `src/cpl/` tree may look like this:

```text
src/cpl/
├── binutils -> binutils-2.46.0
├── binutils-2.46.0
├── binutils-2.46.0.tar.xz
├── gcc -> gcc-16.1.0
├── gcc-16.1.0
├── gcc-16.1.0.tar.gz
├── mingw-w64 -> mingw-w64-v14.0.0
├── mingw-w64-v14.0.0
└── mingw-w64-v14.0.0.tar.bz2
```

The symbolic links are created by `make_cross-compiler.sh`:

* `src/cpl/binutils`
* `src/cpl/gcc`
* `src/cpl/mingw-w64`

They point to the currently selected extracted source directories.

Source preparation is tracked separately from build completion. The script checks
selected source and build-input identities before reusing existing state. It does
not rely on the `src/cpl/gcc` symbolic link alone as evidence of successful
preparation. Interrupted preparation is detected and retried as needed.

**Do not manually delete `src/cpl/`, `build/`, or `install/` to force a fresh
build.** These directories can contain substantial, reusable work. When sources
or build inputs are incompatible with existing artifacts, the script is designed
to reject unsafe reuse rather than silently reuse or automatically discard
valuable build trees.

The special GCC selection `git` uses `src/cpl/gcc-git`. If no build or
installation artifacts are present, the script obtains fresh upstream GCC
sources with a shallow `git clone --depth 1` in a staging directory, then
publishes that checkout as `src/cpl/gcc-git`. An existing checkout may be moved
aside and is not guaranteed to be retained after successful preparation.
If artifacts are already present, the script does not fetch or clone GCC:
it validates the existing checkout and its recorded source identity before
continuing. The script does not use `git pull` to update an existing checkout.

## Building the cross and native compilers

The cross-compiler build is run from the repository root.

Show available GCC versions:

```bash
./make_cross-compiler.sh
```

Build using a specific GCC version, for example:

```bash
./make_cross-compiler.sh 16.1.0
```

The script builds both supported MinGW-w64 targets:

```text
i686-w64-mingw32
x86_64-w64-mingw32
```

For each target, the script first builds a host cross-compiler. On Linux this is a Linux-hosted compiler; on macOS it is a macOS-hosted compiler. It produces Windows binaries.

The generated cross-compilers are installed below:

```text
install/cross/i686-w64-mingw32/
install/cross/x86_64-w64-mingw32/
```

The build sequence for each cross-compiler target is:

1. Build cross Binutils.
2. Install MinGW-w64 headers into the Windows target sysroot.
3. Build the core GCC cross-compiler.
4. Build and install the MinGW-w64 CRT.
5. Finish the full GCC cross-compiler.
6. Build and install Winpthreads.

After the host cross-compiler has been built, the script also builds a Windows-native compiler for the same target. This compiler runs on Windows and produces Windows binaries.

The generated Windows-native compilers are installed below:

```text
install/native/i686-w64-mingw32/
install/native/x86_64-w64-mingw32/
```

The native compiler build sequence is:

1. Build Windows-native Binutils.
2. Build Windows-native GCC.
3. Move the required GCC runtime DLL into the native compiler `bin/` directory.
4. Build and install MinGW-w64 headers and libraries, including Winpthreads.
5. Package the native compiler directory as a ZIP file.

The native compiler ZIP files are written below:

```text
install/native/
```

## Build recovery and completion cache

The compiler driver supports restarting an interrupted build with the same GCC
selection and compatible build inputs. It revisits incomplete stages using the
existing build tools and preserves compatible artifacts instead of starting
from scratch.

After a target has been built, installed, its runtime DLLs relocated, and its
native ZIP package published, the driver can publish a verified per-target
completion record under `build/.cross-complete-<target>`. On subsequent runs,
when the source/configuration identities, record, and metadata of the build and
install trees and ZIP all match, it skips that target's build, installation,
and packaging stages entirely. The two target architectures are checked
independently.

For example, an unchanged repeat may report:

```text
Verified completed target i686-w64-mingw32; skipping.
Verified completed target x86_64-w64-mingw32; skipping.
```

A missing, rejected, or stale record causes normal recovery rather than an
unverified skip. A cache miss does not necessarily rebuild the toolchain from
scratch: compatible intermediate artifacts may be reused, although some stages
can still perform substantial work. The first run after introducing the
completion-cache feature has no existing completion records and can therefore
be expensive. Changing only `NCRS` (parallel job count) does not invalidate a
compatible completed target.

The cache compares filesystem metadata, **not the contents of every artifact**.
It is not a full content-integrity check and does not guarantee that every
internal `make` dependency is fresh. It assumes one writer per build prefix;
do not modify or concurrently build into the same `PREF` while a run is active.
The cache requires suitable GNU utilities; without them the driver falls back
to its existing recovery behavior.

For the record format, compatibility guarantees, failure behavior, portability,
and known limitations, see
[`docs/cross-compiler-resume-spec.md`](docs/cross-compiler-resume-spec.md).

### Isolated integration testing

Use a separately designated `PREF` for real integration testing, not the
prefix holding a valuable production toolchain. `PREF` is the root of the
local source, build, and installation directories used by the driver.
For example:

```bash
PREF="$HOME/src/CRS_BLD-validation" NCRS=4 ./make_cross-compiler.sh 16.1.0
```

Set up and inspect the selected prefix before running this command: an absent
or incompatible build may perform a full toolchain build. Never remove
completion records merely to test the cache, because doing so can trigger an
expensive recovery replay.

## Checking the generated compilers

After the build has completed, check the generated cross-compilers:

```bash
install/cross/i686-w64-mingw32/bin/i686-w64-mingw32-gcc --version
install/cross/x86_64-w64-mingw32/bin/x86_64-w64-mingw32-gcc --version
```

The diagnostic helper can also be used:

```bash
./etc/diagnostics.sh
```

## Compiler targets

The supported MinGW-w64 targets are `i686-w64-mingw32` and
`x86_64-w64-mingw32`. Host cross-compilers are installed under
`install/cross/<target>/`; native Windows toolchains and ZIP packages are
installed under `install/native/<target>/` and
`install/native/<target>.zip`, respectively.

## Package outputs

Compiled package outputs are installed below:

```text
install/pkg/
├── i686-w64-mingw32
│   ├── shared
│   └── static
└── x86_64-w64-mingw32
    ├── shared
    └── static
```

Each package target may provide headers, libraries, binaries and shared data files, depending on the package.

## Typical usage

Prepare compiler source archives under `src/cpl/`, then build the cross and native compiler trees:

```bash
./make_cross-compiler.sh 16.1.0
```

Then build packages in the required order. For example:

```bash
./make_pkgs.sh zlib
./make_pkgs.sh libpng
./make_pkgs.sh glib
./make_pkgs.sh gtk3
```

The complete intended package order is listed in:

```text
order_of_compilation.txt
```

## Notes

This repository is not intended to contain the generated compiler or package outputs.

The generated `build/` and `install/` trees may be large and are machine-local. Do not delete them as a routine troubleshooting step.

For reproducibility, keep the build scripts, package configuration files, patches and package order under version control, but keep downloaded sources and generated build outputs out of Git.

## Development guidance

Contributors and coding assistants should read [`AGENTS.md`](AGENTS.md). The
repository-specific Claude guidance is in [`CLAUDE.md`](CLAUDE.md). Automated
regression tests are available via `tests/run-cross-compiler-tests.sh` and
`python3 -m unittest discover -s tests -p 'test_*.py'`; these do not perform
a real GCC toolchain build.

## Warranty disclaimer

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
