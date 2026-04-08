# imgui-relocator

Automated pipeline to relocate [SpaiR/imgui-java](https://github.com/SpaiR/imgui-java) to a custom Java package namespace. Produces Maven artifacts with renamed packages, renamed native libraries, and renamed JNI symbols — allowing multiple independent copies of imgui-java to coexist in the same JVM without conflicts.

Uses **Zig** as a cross-compilation build system for native libraries, replacing the upstream Ant-based build. Build Linux, Windows, and macOS natives from a single machine.

## Quick Start

```bash
# 1. Edit config.env with your desired package name
nano config.env

# 2. Run the relocation pipeline
./scripts/relocate.sh

# 3. Build natives for your host platform
zig build --release=fast

# 4. Copy native to the work tree and package JARs
zig build copy-to-bin --release=fast
cd work/imgui-java && ./gradlew build -x test -x :example:compileJava

# 5. Publish to local Maven
cd work/imgui-java && ./gradlew publishToMavenLocal
```

Then in your project:

```groovy
repositories {
    mavenLocal()
    mavenCentral()
}

dependencies {
    implementation "com.delta:delta-imgui-java-binding:1.90.0"
    implementation "com.delta:delta-imgui-java-lwjgl3:1.90.0"
    implementation "com.delta:delta-imgui-java-app:1.90.0"
}
```

```java
import com.delta.imgui.ImGui;
import com.delta.imgui.app.Application;

public class Main extends Application {
    @Override
    public void process() {
        ImGui.text("Hello from relocated imgui!");
    }

    public static void main(String[] args) {
        launch(new Main());
    }
}
```

## Why?

If two mods/libraries both ship vanilla `imgui-java`, they collide:
- Same Java packages -> classloader conflicts
- Same native library name -> `System.loadLibrary` loads whichever comes first
- Same JNI symbols -> undefined behavior if the wrong native gets loaded

Relocating gives each consumer their own isolated copy with unique:
- Java package (`com.delta.imgui` instead of `imgui`)
- Native library name (`libdelta-imgui-java64.so` instead of `libimgui-java64.so`)
- JNI symbol prefix (`Java_com_delta_imgui_*` instead of `Java_imgui_*`)
- Resource path (`com/delta/imgui/native-bin/` instead of `io/imgui/java/native-bin/`)
- System property namespace (`com.delta.imgui.library.path` instead of `imgui.library.path`)

## How It Works

### Architecture

```
+---------------------------------------------------------+
|  scripts/relocate.sh                                    |
|                                                         |
|  1. Clone SpaiR/imgui-java at specified tag              |
|  2. Move Java sources: imgui/ -> com/delta/imgui/        |
|  3. Rename package/import/FQCN references in .java       |
|  4. Update FindClass/JNI signatures in C++ native code   |
|  5. Update resource paths, library names, Gradle config  |
|  6. Rewrite publish.gradle for custom Maven server       |
|  7. Gradle: compile Java + generate JNI C++ glue         |
|  8. Fix FindClass paths in generated JNI code            |
|  9. Generate sources.txt manifest for Zig                |
+---------------------------------------------------------+
                          |
                          v
+---------------------------------------------------------+
|  zig build                                              |
|                                                         |
|  Reads sources.txt, compiles all C/C++ in JNI dir.      |
|  On Linux, pins memcpy to GLIBC_2.2.5 for portability.  |
|  Cross-compiles to any target via Zig sysroots.          |
|                                                         |
|  Targets:                                               |
|    x86_64-linux-gnu   -> libdelta-imgui-java64.so        |
|    x86_64-windows-gnu -> delta-imgui-java64.dll          |
|    x86_64-macos       -> libdelta-imgui-java64.dylib     |
|    aarch64-macos      -> libdelta-imgui-java64.dylib     |
+---------------------------------------------------------+
                          |
                          v
+---------------------------------------------------------+
|  Gradle build + publish                                 |
|                                                         |
|  Packages renamed .class files + native into JARs.       |
|  Publishes to custom Maven server or mavenLocal.         |
+---------------------------------------------------------+
```

### What Gets Renamed

| Component | Original | Relocated |
|-----------|----------|-----------|
| Java package | `imgui` | `com.delta.imgui` |
| Directory layout | `imgui/ImGui.java` | `com/delta/imgui/ImGui.java` |
| JNI symbols | `Java_imgui_ImGui_nText` | `Java_com_delta_imgui_ImGui_nText` |
| FindClass paths (C++) | `"imgui/ImGui"` | `"com/delta/imgui/ImGui"` |
| JNI type signatures (C++) | `Limgui/ImVec2;` | `Lcom/delta/imgui/ImVec2;` |
| Native library name | `libimgui-java64.so` | `libdelta-imgui-java64.so` |
| Resource path in JAR | `io/imgui/java/native-bin/` | `com/delta/imgui/native-bin/` |
| Properties key | `imgui.java.version` | `com.delta.imgui.java.version` |
| System properties | `imgui.library.path` | `com.delta.imgui.library.path` |
| Maven group | `io.github.spair` | `com.delta` |
| Artifact IDs | `imgui-java-binding` | `delta-imgui-java-binding` |
| Module names (JPMS) | `imgui.binding` | `com.delta.imgui.binding` |

### What Does NOT Get Renamed

- **`include/imgui/`** -- The upstream Dear ImGui C++ submodule. Not a Java package.
- **`imgui-binding/`** -- Gradle module directory names. Internal structure, not published.
- **`example/`** -- Not relocated or published.

## Configuration

Edit `config.env`:

```bash
UPSTREAM_TAG="v1.90.0"          # Which upstream version to build
TARGET_PKG="com.delta.imgui"    # Target Java package (>= 3 segments)
MAVEN_GROUP="com.delta"         # Maven group ID
ARTIFACT_PREFIX="delta-imgui-java"  # Artifact ID prefix
LIB_NAME="delta-imgui-java64"  # Native library base name
```

Or override via environment variables:

```bash
TARGET_PKG="net.mymod.imgui" MAVEN_GROUP="net.mymod" \
    ARTIFACT_PREFIX="mymod-imgui-java" LIB_NAME="mymod-imgui-java64" \
    ./scripts/relocate.sh
```

## Cross-Compilation with Zig

Zig bundles sysroots for all major targets, so you can build for every platform from one machine:

```bash
zig build --release=fast -Dtarget=x86_64-linux-gnu
zig build --release=fast -Dtarget=x86_64-windows-gnu
zig build --release=fast -Dtarget=x86_64-macos
zig build --release=fast -Dtarget=aarch64-macos
```

Output goes to `zig-out/lib/`. Use `zig build copy-to-bin` to install into `work/imgui-java/bin/` for Gradle packaging.

### glibc Compatibility

The Linux `.so` pins `memcpy` to `GLIBC_2.2.5` via a `.symver` directive (`src/glibc_compat.h`), avoiding the `GLIBC_2.14` dependency that would break older distros. This header is force-included into every C/C++ translation unit on Linux targets.

## Testing

```bash
# Full test suite: cross-compile all platforms + JARs + smoke test
./scripts/test.sh

# Host only (skip cross-compilation)
./scripts/test.sh --skip-cross
```

The test script:
1. Cross-compiles natives for all 4 platforms via Zig
2. Verifies each native artifact was produced
3. Checks the Linux `.so` has no `GLIBC_2.14+` dependency
4. Builds JARs via Gradle
5. Runs Java unit tests
6. Runs a native load smoke test on the host platform

## CI/CD

A GitHub Actions workflow (`.github/workflows/release.yml`) automates the full pipeline:

- **Trigger**: daily cron checks upstream for new tags, or manual `workflow_dispatch`
- **Jobs**: relocate -> cross-compile (4 parallel matrix builds) -> test -> publish -> GitHub release
- **Publish**: pushes to a custom Maven server using bearer token auth

Required secrets:
| Secret | Description |
|--------|-------------|
| `MAVEN_BASE_URL` | Maven repository URL |
| `MAVEN_TOKEN` | Bearer token for Maven auth |
| `MAVEN_REPO_NAME` | Maven repository name |
| `SIGNING_KEY_ID` | GPG key ID (optional) |
| `SIGNING_KEY` | GPG private key (optional) |
| `SIGNING_KEY_PASS` | GPG passphrase (optional) |

## Verification

```bash
./scripts/verify.sh
```

Checks for unrenamed package declarations, imports, FQCNs, C++ JNI paths, resource paths, and verifies renamed files exist.

## Project Layout

```
imgui-relocator/
  config.env              # Configuration: package name, lib name, versions
  build.zig               # Zig build system for cross-compiling natives
  src/
    glibc_compat.h        # glibc memcpy version pin (force-included on Linux)
    glibc_compat.c        # Compiled into .so for versioned symbol emission
  scripts/
    relocate.sh           # Main pipeline: clone -> rename -> generate JNI
    verify.sh             # Post-rename verification checks
    test.sh               # Full build + test suite
  .github/workflows/
    release.yml           # CI/CD: build + publish on upstream release
  work/                   # [gitignored] Clone of imgui-java + build artifacts
  zig-out/                # [gitignored] Zig build output
```

## Requirements

- **Zig** >= 0.14 (for cross-compilation)
- **Java** 8+ (for Gradle compilation)
- **Perl** (for negative-lookbehind regex in rename)
- **Git** (for cloning upstream)

## Upgrading to New Upstream Versions

1. Update `UPSTREAM_TAG` in `config.env`
2. Delete `work/` directory
3. Run `./scripts/relocate.sh`
4. Run `./scripts/verify.sh`
5. If verify fails, check what changed upstream and adjust the script
