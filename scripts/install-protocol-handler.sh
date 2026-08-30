#!/usr/bin/env bash
set -e

# Target directory in Applications or Neovim data dir
APP_DIR="${HOME}/Applications/MSTeamsAuthHandler.app"
mkdir -p "${HOME}/Applications"
mkdir -p "${HOME}/.local/share/nvim/ms-teams"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

TMP_SWIFT=$(mktemp /tmp/msteams_handler.XXXXXX.swift)

cat << 'SWIFT' > "$TMP_SWIFT"
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Exit after a short delay if no URL or after processing
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            NSApp.terminate(nil)
        }
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            NSApp.terminate(nil)
            return
        }

        // 1. Copy full URL to system clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urlString, forType: .string)

        // 2. Write to auth_code.txt in Neovim data dir
        let home = FileManager.default.homeDirectoryForCurrentUser
        let targetFile = home.appendingPathComponent(".local/share/nvim/ms-teams/auth_code.txt")
        try? urlString.write(to: targetFile, atomically: true, encoding: .utf8)

        // 3. Optional desktop notification
        let notification = NSUserNotification()
        notification.title = "ms-teams.nvim"
        notification.informativeText = "Captured Microsoft Teams OAuth code"
        NSUserNotificationCenter.default.deliver(notification)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFT

# Compile Swift binary
swiftc -O "$TMP_SWIFT" -o "$APP_DIR/Contents/MacOS/MSTeamsAuthHandler"
rm -f "$TMP_SWIFT"

# Create Info.plist
cat << 'PLIST_EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.msteams.nvim.authhandler</string>
    <key>CFBundleName</key>
    <string>MSTeamsAuthHandler</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>MSTeamsAuthHandler</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Microsoft AAD Broker Plugin Handler</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>ms-appx-web</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST_EOF

# Register with LaunchServices
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP_DIR"
fi

echo "MSTeamsAuthHandler.app installed successfully at $APP_DIR"
