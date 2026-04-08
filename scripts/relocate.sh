#!/usr/bin/env bash
#
# relocate.sh — Clone upstream imgui-java and rename everything to a custom package.
#
# Usage:
#   ./scripts/relocate.sh                  # uses config.env defaults
#   TARGET_PKG=net.foo.imgui ./scripts/relocate.sh  # override via env
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Load config (env vars take precedence over config.env)
source "$ROOT_DIR/config.env"

# ─── Derived values ──────────────────────────────────────────────────────────

TARGET_PATH="${TARGET_PKG//./\/}"            # com/delta/imgui
ORIG_PKG="imgui"
ORIG_PATH="imgui"
WORK_DIR="$ROOT_DIR/work/imgui-java"

# Validate
if [[ "$(echo "$TARGET_PKG" | tr -cd '.' | wc -c)" -lt 2 ]]; then
    echo "ERROR: TARGET_PKG must have >= 3 segments (got '$TARGET_PKG')"
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  imgui-relocator                                        ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Upstream:    $UPSTREAM_TAG"
echo "║  Target pkg:  $TARGET_PKG"
echo "║  Target path: $TARGET_PATH"
echo "║  Lib name:    $LIB_NAME"
echo "║  Maven group: $MAVEN_GROUP"
echo "║  Artifact:    $ARTIFACT_PREFIX"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Clone upstream ─────────────────────────────────────────────────

if [ -d "$WORK_DIR" ]; then
    echo "[1/8] Work directory exists, cleaning..."
    rm -rf "$WORK_DIR"
fi

echo "[1/8] Cloning upstream $UPSTREAM_TAG..."
git clone --recurse-submodules --branch "$UPSTREAM_TAG" --depth 1 \
    "$UPSTREAM_REPO" "$WORK_DIR"

cd "$WORK_DIR"

# ─── Step 2: Move Java source directories ───────────────────────────────────

echo "[2/8] Moving Java source directories..."

for src in \
    imgui-binding/src/main/java \
    imgui-binding/src/generated/java \
    imgui-binding/src/test/java \
    imgui-lwjgl3/src/main/java \
    imgui-app/src/main/java \
; do
    if [ -d "$src/$ORIG_PATH" ]; then
        mkdir -p "$src/$TARGET_PATH"
        cp -a "$src/$ORIG_PATH/"* "$src/$TARGET_PATH/"
        rm -rf "$src/$ORIG_PATH"
        echo "  Moved: $src/$ORIG_PATH → $src/$TARGET_PATH"
    fi
done

# ─── Step 3: Rename package declarations, imports, and FQCNs ────────────────

echo "[3/8] Renaming Java package references..."

# We do this in two passes to avoid double-replacement.
# Pass 1: package/import lines (anchored patterns)
# Note: old imgui/ dirs are already removed in step 2, so no prune needed.
find . -name '*.java' -path '*/src/*' -print | \
    xargs sed -i \
        -e "s/^package ${ORIG_PKG}/package ${TARGET_PKG}/" \
        -e "s/import ${ORIG_PKG}\./import ${TARGET_PKG}./g"

# Pass 2: Fully-qualified references in code and javadoc.
# We match word-boundary \b to avoid matching "dearlimgui" or similar.
# To prevent double-replacement (com.delta.imgui.ImFoo → com.delta.com.delta.imgui.ImFoo),
# we use a negative lookbehind — sed doesn't support this, so we use perl.
find . -path '*/src/*/java' -type d | while read -r java_root; do
    find "$java_root" -name '*.java' -exec perl -pi -e "
        # Replace imgui.X but not if already preceded by a dot (i.e. already relocated)
        s/(?<!\.)(?<![\/\w])${ORIG_PKG}\./${TARGET_PKG}./g;
    " {} +
done

# Fix any accidental double-replacements (belt and suspenders)
find . -name '*.java' -path '*/src/*' -exec sed -i \
    "s/${TARGET_PKG//./\\.}\.${TARGET_PKG//./\\.}/${TARGET_PKG}/g" {} +

echo "  Package references updated."

# ─── Step 4: Update C++ JNI class paths ─────────────────────────────────────

echo "[4/8] Updating JNI FindClass / signatures in native C++ code..."

find . -path '*/src/main/native' -type d | while read -r native_dir; do
    find "$native_dir" \( -name '*.cpp' -o -name '*.h' \) -exec sed -i \
        -e "s|\"${ORIG_PATH}/|\"${TARGET_PATH}/|g" \
        -e "s|L${ORIG_PATH}/|L${TARGET_PATH}/|g" \
    {} +
done

echo "  JNI paths updated."

# ─── Step 5: Update native resource paths and library names ─────────────────

echo "[5/8] Updating library names and resource paths..."

# ImGui.java — both raw and generated source
find . -name 'ImGui.java' \( -path '*imgui-binding/src/main/*' -o -path '*imgui-binding/src/generated/*' \) \
    -exec sed -i \
        -e "s/\"imgui-java64\"/\"${LIB_NAME}\"/g" \
        -e "s/\"imgui-java-natives\"/\"${ARTIFACT_PREFIX}-natives\"/g" \
        -e "s|io/imgui/java/native-bin/|${TARGET_PATH}/native-bin/|g" \
        -e "s|\"/imgui/imgui-java.properties\"|\"/$(echo "$TARGET_PATH" | sed 's|/|\\/|g')/imgui-java.properties\"|g" \
        -e "s/\"imgui\\.library\\.path\"/\"${TARGET_PKG}.library.path\"/g" \
        -e "s/\"imgui\\.library\\.name\"/\"${TARGET_PKG}.library.name\"/g" \
    {} +

# Move resources directory
if [ -d "imgui-binding/src/main/resources/imgui" ]; then
    mkdir -p "imgui-binding/src/main/resources/$TARGET_PATH"
    mv imgui-binding/src/main/resources/imgui/* "imgui-binding/src/main/resources/$TARGET_PATH/"
    rmdir imgui-binding/src/main/resources/imgui
fi

# Rename key in imgui-java.properties to match the renamed Java code
# (step 3 renames "imgui.java.version" → "<TARGET_PKG>.java.version" in Java sources)
find . -name 'imgui-java.properties' -exec sed -i \
    "s/^imgui\.java\.version/${TARGET_PKG}.java.version/" {} +

echo "  Resource paths updated."

# ─── Step 6: Update Gradle build configuration ──────────────────────────────

echo "[6/8] Updating Gradle build configuration..."

# Root build.gradle — Maven group + hardcode version from tag
# The upstream build.gradle derives version via `git describe --tags`, but the
# .git directory is stripped during CI artifact upload. Replace with the actual tag.
VERSION="${UPSTREAM_TAG#v}"
sed -i "s/group = 'imgui-java'/group = '${MAVEN_GROUP}'/" build.gradle
sed -i "s|version = 'git describe --tags --always'.execute().text.trim().substring(1)|version = '${VERSION}'|" build.gradle

# publish.gradle — Maven coordinates + custom Maven server
sed -i "s/groupId = 'io.github.spair'/groupId = '${MAVEN_GROUP}'/" publish.gradle

# Replace the Sonatype/Maven Central repository block with a custom server.
# MAVEN_URL must be the exact, final repository URL including the repo name,
# e.g. https://maven.example.org/releases — no construction or deduplication.
cat > publish.gradle << 'PUBLISH_EOF'
ext.configurePublishing = { packageName, packageDesc, packageVersion ->
    tasks.register('sourcesJar', Jar) {
        it.dependsOn classes
        it.archiveClassifier.set('sources')
        it.from sourceSets.main.allSource
    }
    tasks.register('javadocJar', Jar) {
        it.dependsOn javadoc
        it.archiveClassifier.set('javadoc')
        it.from javadoc.destinationDir
    }
    publishing {
        repositories {
            maven {
                name = 'Custom'
                // MAVEN_URL: full repository URL, e.g. https://maven.example.org/releases
                def mavenUrl = (System.getenv('MAVEN_URL')?.trim() ?: 'file://localhost/tmp/maven-repo').replaceAll('/+$', '')
                url = mavenUrl
                if (mavenUrl.startsWith('http://') || mavenUrl.startsWith('https://')) {
                    credentials {
                        username = System.getenv('MAVEN_USER')?.trim() ?: ''
                        password = System.getenv('MAVEN_TOKEN')?.trim() ?: ''
                    }
                }
            }
        }
        publications {
            imgui(MavenPublication) {
                groupId = 'MAVEN_GROUP_PLACEHOLDER'
                artifactId = packageName
                version = packageVersion

                from components.java
                artifact sourcesJar
                artifact javadocJar

                pom {
                    name = packageName
                    description = packageDesc
                    url = 'https://github.com/SpaiR/imgui-java'
                    licenses {
                        license {
                            name = 'MIT License'
                            url = 'https://opensource.org/license/mit/'
                        }
                    }
                }
            }
        }
    }
    if (System.getenv('SIGNING_KEY_ID') != null) {
        signing {
            def signingKeyId = System.getenv('SIGNING_KEY_ID')?.trim() ?: ''
            def signingKey = System.getenv('SIGNING_KEY')?.trim() ?: ''
            def signingKeyPass = System.getenv('SIGNING_KEY_PASS')?.trim() ?: ''
            useInMemoryPgpKeys(signingKeyId, signingKey, signingKeyPass)
            sign publishing.publications.imgui
        }
    }
}
PUBLISH_EOF
sed -i "s/MAVEN_GROUP_PLACEHOLDER/${MAVEN_GROUP}/" publish.gradle

# imgui-binding build.gradle
sed -i \
    -e "s/configurePublishing('imgui-java-binding'/configurePublishing('${ARTIFACT_PREFIX}-binding'/" \
    -e "s/'Automatic-Module-Name': 'imgui.binding'/'Automatic-Module-Name': '${TARGET_PKG}.binding'/" \
    imgui-binding/build.gradle

# imgui-lwjgl3 build.gradle
sed -i \
    -e "s/configurePublishing('imgui-java-lwjgl3'/configurePublishing('${ARTIFACT_PREFIX}-lwjgl3'/" \
    -e "s/'Automatic-Module-Name': 'imgui.lwjgl3'/'Automatic-Module-Name': '${TARGET_PKG}.lwjgl3'/" \
    imgui-lwjgl3/build.gradle

# imgui-app build.gradle
sed -i \
    -e "s/imgui-java64.dll/${LIB_NAME}.dll/g" \
    -e "s/libimgui-java64.so/lib${LIB_NAME}.so/g" \
    -e "s/libimgui-java64.dylib/lib${LIB_NAME}.dylib/g" \
    -e "s|io/imgui/java/native-bin/|${TARGET_PATH}/native-bin/|g" \
    -e "s/'Automatic-Module-Name': 'imgui.app'/'Automatic-Module-Name': '${TARGET_PKG}.app'/" \
    -e "s/configurePublishing('imgui-java-app'/configurePublishing('${ARTIFACT_PREFIX}-app'/" \
    imgui-app/build.gradle

# imgui-binding-natives build.gradle
# Replace full filenames explicitly to avoid double-replacement of the
# 'imgui-java64' substring inside 'libimgui-java64'.
sed -i \
    -e "s/imgui-java-natives/${ARTIFACT_PREFIX}-natives/g" \
    -e "s/libimgui-java64\.so/lib${LIB_NAME}.so/g" \
    -e "s/libimgui-java64\.dylib/lib${LIB_NAME}.dylib/g" \
    -e "s/imgui-java64\.dll/${LIB_NAME}.dll/g" \
    -e "s|io/imgui/java/native-bin/|${TARGET_PATH}/native-bin/|g" \
    -e "s/'imgui\.natives\./'${TARGET_PKG}.natives./g" \
    imgui-binding-natives/build.gradle

echo "  Gradle config updated."

# ─── Step 7: Update native build system (GenerateLibs.groovy + build.sh) ────

echo "[7/8] Updating native build configuration..."

# GenerateLibs.groovy
sed -i \
    -e "s/BuildConfig('imgui-java'/BuildConfig('${ARTIFACT_PREFIX}'/" \
    -e "s/imgui-java64/${LIB_NAME}/g" \
    -e "s/libimgui-java64/lib${LIB_NAME}/g" \
    buildSrc/src/main/groovy/tool/generator/GenerateLibs.groovy

# build.sh
sed -i \
    -e "s/imgui-java64/${LIB_NAME}/g" \
    -e "s/libimgui-java64/lib${LIB_NAME}/g" \
    buildSrc/scripts/build.sh

echo "  Native build config updated."

# ─── Step 8: Rename prebuilt binaries in bin/ ────────────────────────────────

echo "[8/8] Renaming prebuilt binaries..."

cd bin
[ -f "imgui-java64.dll" ]       && mv "imgui-java64.dll"       "${LIB_NAME}.dll"
[ -f "libimgui-java64.so" ]     && mv "libimgui-java64.so"     "lib${LIB_NAME}.so"
[ -f "libimgui-java64.dylib" ]  && mv "libimgui-java64.dylib"  "lib${LIB_NAME}.dylib"
cd ..

# ─── Step 9: Compile Java + generate JNI C++ glue ───────────────────────────

echo "[9/10] Compiling Java and generating JNI C++ glue..."

# Compile Java sources (the JNI generator needs compiled classes)
./gradlew imgui-binding:assemble -x test -x :example:compileJava --quiet

# Run the JNI code generator. This populates build/jni with:
#   - Generated JNI .cpp/.h files (from renamed Java sources → correct symbols)
#   - Copied upstream Dear ImGui .cpp/.h sources
#   - Bundled JNI headers for all platforms
#
# Patch GenerateLibs.groovy to skip the Ant/gcc compilation phase —
# Zig handles all native compilation. We insert an early return after
# the JNI source generation + file copying, before the Ant build stage.
sed -i '/Generate platform dependant ant configs/i\        return // Skip Ant/gcc build — Zig compiles natives' \
    buildSrc/src/main/groovy/tool/generator/GenerateLibs.groovy
./gradlew imgui-binding:generateLibs -Denvs=linux -Dlocal --quiet

JNI_DIR="imgui-binding/build/jni"
if [ ! -d "$JNI_DIR" ]; then
    echo "ERROR: JNI dir not generated at $JNI_DIR"
    exit 1
fi

echo "  JNI C++ sources generated."

# The JNI code generator hardcodes FindClass paths using the original package.
# Fix them in the generated C++ files.
echo "  Fixing FindClass paths in generated JNI code..."
find "$JNI_DIR" \( -name '*.cpp' -o -name '*.h' \) -exec sed -i \
    -e "s|\"${ORIG_PATH}/|\"${TARGET_PATH}/|g" \
    -e "s|L${ORIG_PATH}/|L${TARGET_PATH}/|g" \
{} +

# ─── Bundle JNI headers for cross-compilation ──────────────────────────────

echo "  Bundling JNI headers for cross-compilation..."

# Copy jni.h from the build JDK, then provide jni_md.h for all target platforms.
# jni.h is platform-independent; jni_md.h only differs in type sizes and calling
# conventions. We put a universal jni_md.h alongside jni.h so it's found via the
# same include path regardless of cross-compilation target.
JNI_HEADERS_DIR="$JNI_DIR/jni-headers"
mkdir -p "$JNI_HEADERS_DIR"

JAVA_HOME_RESOLVED="${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which javac))))}"
if [ -f "$JAVA_HOME_RESOLVED/include/jni.h" ]; then
    cp "$JAVA_HOME_RESOLVED/include/jni.h" "$JNI_HEADERS_DIR/"
else
    echo "WARNING: Could not find jni.h in JAVA_HOME ($JAVA_HOME_RESOLVED)"
fi

# Write a universal jni_md.h that works for Linux, macOS, and Windows (all 64-bit)
cat > "$JNI_HEADERS_DIR/jni_md.h" << 'JNI_MD_EOF'
#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_

#ifndef __has_attribute
  #define __has_attribute(x) 0
#endif

#if defined(_WIN32)
  #define JNIEXPORT __declspec(dllexport)
  #define JNIIMPORT __declspec(dllimport)
  #define JNICALL   __stdcall
  typedef int jint;
  typedef __int64 jlong;
#else
  #if (defined(__GNUC__) && ((__GNUC__ > 4) || (__GNUC__ == 4) && (__GNUC_MINOR__ > 2))) || __has_attribute(visibility)
    #define JNIEXPORT __attribute__((visibility("default")))
    #define JNIIMPORT __attribute__((visibility("default")))
  #else
    #define JNIEXPORT
    #define JNIIMPORT
  #endif
  #define JNICALL
  typedef int jint;
  #ifdef _LP64
    typedef long jlong;
  #else
    typedef long long jlong;
  #endif
#endif

typedef signed char jbyte;

#endif /* !_JAVASOFT_JNI_MD_H_ */
JNI_MD_EOF

echo "  JNI headers bundled at $JNI_HEADERS_DIR"

# ─── Step 10: Generate source manifest for Zig build ────────────────────────

echo "[10/10] Generating sources.txt manifest for Zig build..."

find "$JNI_DIR" -maxdepth 1 -name '*.cpp' -printf '%f\n' | sort > "$JNI_DIR/sources.txt"
CPP_COUNT=$(wc -l < "$JNI_DIR/sources.txt")
echo "  $CPP_COUNT C++ source files listed in sources.txt"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Relocation complete!"
echo ""
echo "  Verify:   cd $ROOT_DIR && ./scripts/verify.sh"
echo "  Build:    cd $ROOT_DIR && zig build --release=fast"
echo "  All plat: zig build --release=fast -Dtarget=x86_64-linux-gnu"
echo "            zig build --release=fast -Dtarget=x86_64-windows-gnu"
echo "            zig build --release=fast -Dtarget=aarch64-macos"
echo "            zig build --release=fast -Dtarget=x86_64-macos"
echo "  Package:  cd work/imgui-java && ./gradlew build -x test -x :example:compileJava"
echo "  Publish:  cd work/imgui-java && ./gradlew publishToMavenLocal"
echo "════════════════════════════════════════════════════════════"