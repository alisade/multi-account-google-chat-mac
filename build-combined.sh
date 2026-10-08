#!/bin/sh
# build-combined.sh -- build the multi-workspace Chat app (Slack-style).
#
# One window, one Dock icon, a left rail to switch between the workspaces in
# workspaces.conf. Each workspace's web view is backed by its OWN isolated
# persistent store (WKWebsiteDataStore(forIdentifier:), macOS 14+), so several
# Google accounts stay signed in at once. Sign in once per workspace.
#
# Usage:
#   ./build-combined.sh                            # -> ~/Chats.app
#   OUT_DIR=/Applications ./build-combined.sh
#   APP_NAME="Work Chat" BUNDLE_ID=com.local.workchat ./build-combined.sh
#   CONFIG=/path/to/other.conf ./build-combined.sh
#   ICON_STYLE=logos ./build-combined.sh             # app icon from workspace logos

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="${HERE}/ChatApp.swift"
OUT_DIR="${OUT_DIR:-$HOME}"
APP_NAME="${APP_NAME:-Chats}"
BUNDLE_ID="${BUNDLE_ID:-com.local.chats}"
APPPATH="${OUT_DIR}/$(printf '%s' "${APP_NAME}" | tr ' ' '-').app"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

sh "${HERE}/read-config.sh" > "${WORK}/workspaces"

# Compile the shared binary (cached next to the source).
BIN="${HERE}/.chatapp.bin"
if [ ! -x "${BIN}" ] || [ "${SRC}" -nt "${BIN}" ]; then
  echo "compiling ${SRC} ..."
  swiftc -O -framework Cocoa -framework WebKit "${SRC}" -o "${BIN}"
fi

rm -rf "${APPPATH}"
mkdir -p "${APPPATH}/Contents/MacOS" "${APPPATH}/Contents/Resources"
/bin/cp "${BIN}" "${APPPATH}/Contents/MacOS/chatapp"
chmod +x "${APPPATH}/Contents/MacOS/chatapp"

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Copy each logo into Resources as ws<N>.png and emit its Workspaces entry.
i=0
logos=""
entries=""
while IFS='|' read -r name url icon store; do
  i=$((i + 1))
  icon_key=""
  if [ -n "${icon}" ]; then
    /bin/cp "${icon}" "${APPPATH}/Contents/Resources/ws${i}.png"
    icon_key="<key>Icon</key><string>ws${i}.png</string>"
    logos="${logos} ws${i}.png"
  fi
  entries="${entries}
		<dict>
			<key>Name</key><string>$(xml "${name}")</string>
			<key>URL</key><string>$(xml "${url}")</string>
			<key>StoreID</key><string>${store}</string>
			${icon_key}
		</dict>"
done < "${WORK}/workspaces"

# App icon: the app's own drawn icon (draw-app-icon.swift) by default, or with
# ICON_STYLE=logos the workspace logos composited onto one card.
case "${ICON_STYLE:-app}" in
  app|logos) ;;
  *) echo "warning: unknown ICON_STYLE '${ICON_STYLE}' (use app or logos); using app" >&2 ;;
esac
echo "drawing app icon ..."
if [ "${ICON_STYLE:-app}" = "logos" ] && [ -n "${logos}" ]; then
  swiftc -O -framework Cocoa "${HERE}/compose-icon.swift" -o "${WORK}/compose-icon"
  # shellcheck disable=SC2086  # logos is a space-separated list of plain names
  (cd "${APPPATH}/Contents/Resources" && "${WORK}/compose-icon" "${WORK}/icon.png" ${logos})
else
  swiftc -O -framework Cocoa "${HERE}/draw-app-icon.swift" -o "${WORK}/draw-app-icon"
  "${WORK}/draw-app-icon" "${WORK}/icon.png"
fi
sh "${HERE}/make-icns.sh" "${WORK}/icon.png" "${APPPATH}/Contents/Resources/app.icns"
ICON_KEY='<key>CFBundleIconFile</key><string>app.icns</string>'

cat > "${APPPATH}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>chatapp</string>
	${ICON_KEY}
	<key>CFBundleIdentifier</key><string>$(xml "${BUNDLE_ID}")</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$(xml "${APP_NAME}")</string>
	<key>CFBundleDisplayName</key><string>$(xml "${APP_NAME}")</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSCameraUsageDescription</key><string>Google Chat huddles and calls use your camera.</string>
	<key>NSMicrophoneUsageDescription</key><string>Google Chat huddles and calls use your microphone.</string>
	<key>Workspaces</key>
	<array>${entries}
	</array>
</dict></plist>
EOF

xattr -cr "${APPPATH}" 2>/dev/null || true       # strip detritus that trips codesign
codesign --force --deep -s - "${APPPATH}" >/dev/null 2>&1 || true
touch "${APPPATH}"
echo "built: ${APPPATH}  (${APP_NAME}, ${i} workspaces)"
