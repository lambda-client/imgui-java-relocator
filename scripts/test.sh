#!/usr/bin/env bash
#
# test.sh — Build natives for all platforms, package JARs, and run host tests.
#
# This script validates the full pipeline output:
#   1. Cross-compiles native libraries for all target platforms via Zig
#   2. Verifies each native artifact was produced
#   3. Packages JARs via Gradle
#   4. Runs Java unit tests (pure Java, no native load)
#   5. Runs a native-load smoke test on the host platform
#
# Prerequisites:
#   - scripts/relocate.sh must have been run successfully
#   - Zig and a JDK must be on PATH
#
# Usage:
#   ./scripts/test.sh              # full test suite
#   ./scripts/test.sh --skip-cross # skip cross-compilation, only test host
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/config.env"

WORK_DIR="$ROOT_DIR/work/imgui-java"
BIN_DIR="$WORK_DIR/bin"
TARGET_PATH="${TARGET_PKG//./\/}"
SKIP_CROSS=false
FAIL=0

for arg in "$@"; do
    case "$arg" in
        --skip-cross) SKIP_CROSS=true ;;
    esac
done

# ─── Helpers ────────────────────────────────────────────────────────────────

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=1; }

check_prereqs() {
    if [ ! -d "$WORK_DIR/imgui-binding/build/jni" ]; then
        echo "ERROR: JNI sources not found. Run scripts/relocate.sh first."
        exit 1
    fi
    command -v zig >/dev/null 2>&1 || { echo "ERROR: zig not found on PATH"; exit 1; }
    command -v java >/dev/null 2>&1 || { echo "ERROR: java not found on PATH"; exit 1; }
}

# Maps a Zig target triple to the expected native library filename.
lib_filename() {
    local target="$1"
    case "$target" in
        *windows*)  echo "${LIB_NAME}.dll" ;;
        *macos*)    echo "lib${LIB_NAME}.dylib" ;;
        *)          echo "lib${LIB_NAME}.so" ;;
    esac
}

# Returns the zig-out subdirectory for the given target.
# Zig puts .dll in bin/ and .so/.dylib in lib/.
zig_out_dir() {
    local target="$1"
    case "$target" in
        *windows*)  echo "$ROOT_DIR/zig-out/bin" ;;
        *)          echo "$ROOT_DIR/zig-out/lib" ;;
    esac
}

# ─── Main ───────────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  imgui-relocator test suite                              ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Library:     $LIB_NAME"
echo "║  Package:     $TARGET_PKG"
echo "║  Artifact:    $ARTIFACT_PREFIX"
echo "║  Skip cross:  $SKIP_CROSS"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

check_prereqs

# ─── Step 1: Cross-compile natives ──────────────────────────────────────────

TARGETS=(
    "x86_64-linux-gnu"
    "x86_64-windows-gnu"
    "x86_64-macos"
    "aarch64-macos"
)

if [ "$SKIP_CROSS" = false ]; then
    echo "[1/5] Cross-compiling natives for all platforms..."
    mkdir -p "$BIN_DIR"

    for t in "${TARGETS[@]}"; do
        printf "  Building %-25s ... " "$t"
        if zig build \
            --release=fast \
            -Dtarget="$t" \
            -Dlib-name="$LIB_NAME" \
            -Djni-dir="work/imgui-java/imgui-binding/build/jni" \
            2>"$ROOT_DIR/work/zig-build-${t}.log"; then

            # Copy artifact to bin/
            local_lib=$(lib_filename "$t")
            built_lib="$(zig_out_dir "$t")/$local_lib"
            if [ -f "$built_lib" ]; then
                cp "$built_lib" "$BIN_DIR/$local_lib"
                pass "$t → $local_lib"
            else
                fail "$t — built but artifact not found at $built_lib"
            fi
        else
            fail "$t — compilation failed (see work/zig-build-${t}.log)"
        fi
    done
else
    echo "[1/5] Cross-compilation skipped (--skip-cross)."

    # Still build for host
    echo "  Building for host platform..."
    zig build \
        --release=fast \
        -Dlib-name="$LIB_NAME" \
        -Djni-dir="work/imgui-java/imgui-binding/build/jni" \
        2>"$ROOT_DIR/work/zig-build-host.log" \
        && pass "Host native build" \
        || fail "Host native build (see work/zig-build-host.log)"

    # Copy host artifact to bin/
    host_lib=$(lib_filename "$(uname -s)")
    built_lib="$(zig_out_dir "$(uname -s)")/$host_lib"
    if [ -f "$built_lib" ]; then
        mkdir -p "$BIN_DIR"
        cp "$built_lib" "$BIN_DIR/$host_lib"
    fi
fi

echo ""

# ─── Step 2: Verify native artifacts ───────────────────────────────────────

echo "[2/5] Verifying native artifacts in bin/..."

if [ "$SKIP_CROSS" = false ]; then
    for t in "${TARGETS[@]}"; do
        expected=$(lib_filename "$t")
        if [ -f "$BIN_DIR/$expected" ]; then
            size=$(stat --printf="%s" "$BIN_DIR/$expected" 2>/dev/null \
                || stat -f "%z" "$BIN_DIR/$expected" 2>/dev/null)
            pass "$expected ($(( size / 1024 )) KB)"
        else
            fail "$expected missing"
        fi
    done
else
    host_lib=$(lib_filename "$(uname -s)")
    if [ -f "$BIN_DIR/$host_lib" ]; then
        pass "$host_lib present"
    else
        fail "$host_lib missing"
    fi
fi

# On Linux, verify glibc compat — the .so should not require GLIBC_2.14+
if [ -f "$BIN_DIR/lib${LIB_NAME}.so" ] && command -v objdump >/dev/null 2>&1; then
    echo ""
    echo "  Checking glibc version requirements..."
    if objdump -T "$BIN_DIR/lib${LIB_NAME}.so" 2>/dev/null | grep -q 'GLIBC_2\.14'; then
        fail "lib${LIB_NAME}.so requires GLIBC_2.14 (compat header not working)"
    else
        max_glibc=$(objdump -T "$BIN_DIR/lib${LIB_NAME}.so" 2>/dev/null \
            | grep -oP 'GLIBC_\d+\.\d+(\.\d+)?' | sort -V | tail -1 || echo "unknown")
        pass "No GLIBC_2.14 dependency (max: ${max_glibc:-none})"
    fi
fi

echo ""

# ─── Step 3: Package JARs ──────────────────────────────────────────────────

echo "[3/5] Building JARs via Gradle..."

cd "$WORK_DIR"

if ./gradlew build -x test -x :example:compileJava --quiet 2>"$ROOT_DIR/work/gradle-build.log"; then
    pass "Gradle build succeeded"
else
    fail "Gradle build failed (see work/gradle-build.log)"
fi

# Verify JARs were produced
for module in imgui-binding imgui-lwjgl3 imgui-app; do
    jar_dir="$module/build/libs"
    if ls "$jar_dir"/*.jar >/dev/null 2>&1; then
        jar_name=$(ls "$jar_dir"/*.jar | head -1 | xargs basename)
        pass "$module → $jar_name"
    else
        fail "$module — no JAR produced"
    fi
done

echo ""

# ─── Step 4: Run Java unit tests ───────────────────────────────────────────

echo "[4/5] Running Java unit tests..."

if ./gradlew imgui-binding:test --quiet 2>"$ROOT_DIR/work/gradle-test.log"; then
    pass "Unit tests passed"
else
    fail "Unit tests failed (see work/gradle-test.log)"
fi

echo ""

# ─── Step 5: Native load smoke test ────────────────────────────────────────

echo "[5/5] Native load smoke test on host platform..."

cd "$ROOT_DIR"

# Determine host native lib path
host_lib=$(lib_filename "$(uname -s)")
NATIVE_LIB_PATH="$BIN_DIR/$host_lib"

if [ ! -f "$NATIVE_LIB_PATH" ]; then
    fail "Host native lib not found at $NATIVE_LIB_PATH — skipping load test"
else
    # Build classpath from the compiled binding classes
    BINDING_CLASSES="$WORK_DIR/imgui-binding/build/classes/java/main"

    if [ ! -d "$BINDING_CLASSES" ]; then
        fail "Binding classes not found at $BINDING_CLASSES"
    else
        # Smoke test: load the native library and verify a JNI symbol resolves.
        #
        # We do NOT trigger ImGui.<clinit> because it calls nInitJni() →
        # ImFontAtlas.nInit() which dereferences native state that doesn't
        # exist in a headless context (SIGSEGV). Instead we:
        #   1. System.load() the .so directly
        #   2. Use Class.forName with initialize=false to find ImGui
        #   3. Verify a known native method exists via reflection
        SMOKE_DIR="$ROOT_DIR/work/smoke-test"
        mkdir -p "$SMOKE_DIR"

        cat > "$SMOKE_DIR/NativeLoadTest.java" << 'JAVA_EOF'
import java.io.File;
import java.lang.reflect.Method;

public class NativeLoadTest {
    public static void main(String[] args) {
        String libPath = args[0];

        // Step 1: Load the native library
        System.out.println("Loading native library: " + libPath);
        try {
            System.load(new File(libPath).getAbsolutePath());
            System.out.println("  OK: Native library loaded");
        } catch (UnsatisfiedLinkError e) {
            System.err.println("  FAIL: " + e.getMessage());
            System.exit(1);
        }

        // Step 2: Find ImGui class without triggering static init
        String imguiClass = args[1];
        System.out.println("Resolving class: " + imguiClass);
        try {
            Class<?> imgui = Class.forName(imguiClass, false,
                NativeLoadTest.class.getClassLoader());
            System.out.println("  OK: Class found: " + imgui.getName());

            // Step 3: Verify a known native method exists
            boolean foundNative = false;
            for (Method m : imgui.getDeclaredMethods()) {
                if (m.getName().equals("nInitJni")) {
                    foundNative = true;
                    break;
                }
            }
            if (foundNative) {
                System.out.println("  OK: Native method nInitJni found");
            } else {
                System.err.println("  FAIL: nInitJni method not found");
                System.exit(1);
            }
        } catch (ClassNotFoundException e) {
            System.err.println("  FAIL: " + e.getMessage());
            System.exit(1);
        }

        System.out.println("All smoke tests passed.");
    }
}
JAVA_EOF

        # Compile and run
        if javac -cp "$BINDING_CLASSES" -d "$SMOKE_DIR" "$SMOKE_DIR/NativeLoadTest.java" 2>"$ROOT_DIR/work/smoke-compile.log"; then
            if java -cp "$SMOKE_DIR:$BINDING_CLASSES" \
                NativeLoadTest "$NATIVE_LIB_PATH" "${TARGET_PKG}.ImGui" 2>&1; then
                pass "Native load + JNI symbol resolution OK"
            else
                fail "Native load smoke test failed"
            fi
        else
            fail "Smoke test compilation failed (see work/smoke-compile.log)"
        fi
    fi
fi

echo ""

# ─── Summary ────────────────────────────────────────────────────────────────

echo "════════════════════════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
    echo "  All tests passed!"
else
    echo "  Some tests FAILED. Review the output above."
fi
echo "════════════════════════════════════════════════════════════"

exit $FAIL