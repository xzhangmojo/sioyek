#!/usr/bin/env bash
set -e
# prerequisite: brew install qt

#sys_glut_clfags=`pkg-config --cflags glut gl`
#sys_glut_libs=`pkg-config --libs glut gl`
#sys_harfbuzz_clfags=`pkg-config --cflags harfbuzz`
#sys_harfbuzz_libs=`pkg-config --libs harfbuzz`

if [ -z ${MAKE_PARALLEL+x} ]; then export MAKE_PARALLEL=$(sysctl -n hw.logicalcpu); else echo "MAKE_PARALLEL defined"; fi
echo "MAKE_PARALLEL set to $MAKE_PARALLEL"

if [ ! -f mupdf/Makefile ] || [ ! -f zlib/zlib.h ]; then
	git submodule update --init --recursive
fi

cd mupdf
#make USE_SYSTEM_HARFBUZZ=yes USE_SYSTEM_GLUT=yes SYS_GLUT_CFLAGS="${sys_glut_clfags}" SYS_GLUT_LIBS="${sys_glut_libs}" SYS_HARFBUZZ_CFLAGS="${sys_harfbuzz_clfags}" SYS_HARFBUZZ_LIBS="${sys_harfbuzz_libs}" -j 4
make HAVE_GLUT=no -j$MAKE_PARALLEL
cd ..

# set the deployment target to the current macOS version without modifying the tracked .pro file
DEPLOYMENT_TARGET="QMAKE_MACOSX_DEPLOYMENT_TARGET = $(sw_vers -productVersion | cut -d. -f1)"

if [[ $1 == portable ]]; then
	qmake pdf_viewer_build_config.pro -after "$DEPLOYMENT_TARGET"
else
	qmake "CONFIG+=non_portable" pdf_viewer_build_config.pro -after "$DEPLOYMENT_TARGET"
fi

make -j$MAKE_PARALLEL

rm -rf build 2> /dev/null
mkdir build
mv sioyek.app build/
cp -r pdf_viewer/shaders build/sioyek.app/Contents/Resources/shaders

cp pdf_viewer/prefs.config build/sioyek.app/Contents/Resources/prefs.config
cp pdf_viewer/prefs_user.config build/sioyek.app/Contents/Resources/prefs_user.config
cp pdf_viewer/keys.config build/sioyek.app/Contents/Resources/keys.config
cp pdf_viewer/keys_user.config build/sioyek.app/Contents/Resources/keys_user.config
cp tutorial.pdf build/sioyek.app/Contents/Resources/tutorial.pdf

# Capture the current PATH
CURRENT_PATH=$(echo $PATH)

# Define the path to the Info.plist file inside the app bundle
INFO_PLIST="build/sioyek.app/Contents/Info.plist"

# Add LSEnvironment key with PATH to Info.plist
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" || echo "LSEnvironment already exists"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:PATH string $CURRENT_PATH" "$INFO_PLIST" || /usr/libexec/PlistBuddy -c "Set :LSEnvironment:PATH $CURRENT_PATH" "$INFO_PLIST"

# Hack is required to avoid race condition in macos in CI
# See https://github.com/actions/runner-images/issues/7522
if [[ -n "$GITHUB_ACTIONS" ]]; then
  echo killing...; sudo pkill -9 XProtect >/dev/null || true;
  echo waiting...; while pgrep XProtect; do sleep 3; done;
fi

sleep 5

# mac deploys with qml currently don't work due to a qt bug
# macdeployqt build/sioyek.app -qmldir=./pdf_viewer/touchui -dmg
# with homebrew's qt, macdeployqt exits with an error because some plugins that sioyek doesn't use
# (e.g. imageformats/libqpdf, platforminputcontexts/libqtvirtualkeyboardplugin) depend on frameworks it
# can't resolve, so we tolerate the failure and remove those plugins below
macdeployqt build/sioyek.app || echo "macdeployqt reported errors, removing plugins with unresolved dependencies"

for plugin in $(find build/sioyek.app/Contents/PlugIns -name "*.dylib"); do
	for framework in $(otool -L "$plugin" | grep -o "@rpath/[^/]*\.framework" | sed "s|@rpath/||"); do
		if [ ! -d "build/sioyek.app/Contents/Frameworks/$framework" ]; then
			echo "removing $plugin (missing $framework)"
			rm "$plugin"
			break
		fi
	done
done
find build/sioyek.app/Contents/PlugIns -type d -empty -delete

# sign with SIOYEK_SIGN_IDENTITY if set (name of a code signing certificate in the keychain), otherwise ad-hoc
codesign --force --deep --sign "${SIOYEK_SIGN_IDENTITY:--}" build/sioyek.app

hdiutil create -volname sioyek -srcfolder build/sioyek.app -ov -format UDZO build/sioyek.dmg

zip -r sioyek-release-mac.zip build/sioyek.dmg
