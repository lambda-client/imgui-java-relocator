#!/usr/bin/env bash
#
# verify.sh — Post-rename sanity checks.
# Verifies that no leftover references to the original package remain.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$ROOT_DIR/config.env"

TARGET_PATH="${TARGET_PKG//./\/}"
WORK_DIR="$ROOT_DIR/work/imgui-java"
FAIL=0

if [ ! -d "$WORK_DIR" ]; then
    echo "ERROR: $WORK_DIR does not exist. Run relocate.sh first."
    exit 1
fi

cd "$WORK_DIR"

echo "Verifying relocation to $TARGET_PKG..."
echo ""

# ─── Check 1: No unrenamed Java package declarations ────────────────────────

echo -n "  [1/6] Java package declarations... "
if grep -rn '^package imgui' --include='*.java' \
    imgui-binding/src/generated/java \
    imgui-binding/src/main/java \
    imgui-lwjgl3/src/main/java \
    imgui-app/src/main/java 2>/dev/null; then
    echo "FAIL: unrenamed package declarations found"
    FAIL=1
else
    echo "OK"
fi

# ─── Check 2: No unrenamed Java imports ──────────────────────────────────────

echo -n "  [2/6] Java import statements... "
if grep -rn 'import imgui\.' --include='*.java' \
    imgui-binding/src/generated/java \
    imgui-binding/src/main/java \
    imgui-lwjgl3/src/main/java \
    imgui-app/src/main/java 2>/dev/null; then
    echo "FAIL: unrenamed imports found"
    FAIL=1
else
    echo "OK"
fi

# ─── Check 3: No unrenamed FQCNs (imgui.ImXxx, imgui.flag.Xxx, etc.) ────────

echo -n "  [3/6] Fully-qualified class references... "
# Look for imgui.Im or imgui.flag etc. that aren't in comments or strings about Dear ImGui
FQCN_HITS=$(grep -rn '\bimgui\.\(Im\|flag\|callback\|type\|internal\|binding\|extension\|gl3\|glfw\|app\)' \
    --include='*.java' \
    imgui-binding/src/generated/java \
    imgui-binding/src/main/java \
    imgui-lwjgl3/src/main/java \
    imgui-app/src/main/java 2>/dev/null | \
    grep -v 'com\..*\.imgui\.' | \
    grep -v '^\s*//' | \
    grep -v '^\s*\*' || true)
if [ -n "$FQCN_HITS" ]; then
    echo "FAIL: unrenamed fully-qualified references found:"
    echo "$FQCN_HITS" | head -10
    FAIL=1
else
    echo "OK"
fi

# ─── Check 4: No unrenamed C++ JNI paths ────────────────────────────────────

echo -n "  [4/6] C++ JNI FindClass / signatures... "
if grep -rn '"imgui/' --include='*.cpp' --include='*.h' \
    imgui-binding/src/main/native 2>/dev/null; then
    echo "FAIL: unrenamed JNI paths in native code"
    FAIL=1
else
    echo "OK"
fi

# ─── Check 5: No old resource paths ─────────────────────────────────────────

echo -n "  [5/6] Resource paths (io/imgui/java)... "
if grep -rn 'io/imgui/java' --include='*.java' --include='*.gradle' \
    imgui-binding imgui-lwjgl3 imgui-app imgui-binding-natives 2>/dev/null; then
    echo "FAIL: old resource paths found"
    FAIL=1
else
    echo "OK"
fi

# ─── Check 6: Renamed files exist ───────────────────────────────────────────

echo -n "  [6/6] Renamed source files exist... "
if find . -path "*/${TARGET_PATH}/ImGui.java" | grep -q .; then
    echo "OK"
else
    echo "FAIL: $TARGET_PATH/ImGui.java not found"
    FAIL=1
fi

echo ""
if [ $FAIL -eq 0 ]; then
    echo "All checks passed."
else
    echo "Some checks FAILED. Review the output above."
    exit 1
fi
