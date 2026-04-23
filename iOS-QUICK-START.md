# iOS App Signing - Quick Start

This is a quick reference for setting up and building the CpdbiOS app. For detailed instructions, see `iOS-SIGNING-SETUP.md`.

## Prerequisites Checklist

- [ ] Apple Developer Account
- [ ] Xcode installed
- [ ] iOS device registered (for physical device testing)
- [ ] App ID created: `net.phfactor.cpdb.ios`
- [ ] iCloud capability enabled with container: `iCloud.net.phfactor.cpdb`
- [ ] Push Notifications enabled
- [ ] Development provisioning profile downloaded

## Quick Setup (First Time)

### 1. Apple Developer Portal Setup

```bash
# Open the developer portal
open "https://developer.apple.com/account/resources/identifiers/list"
```

Create App ID with:
- Bundle ID: `net.phfactor.cpdb.ios`
- Capabilities: iCloud (CloudKit), Push Notifications
- iCloud Container: `iCloud.net.phfactor.cpdb` (already exists from Mac app)

### 2. Get Your Team ID

```bash
# Find your Team ID in Xcode
open "https://developer.apple.com/account"
# Look for "Team ID" in the Membership section (10 characters, like ABC1234567)
```

### 3. Build for Simulator (Easiest - No Signing Required)

```bash
# Make the build script executable
chmod +x build-ios.sh

# Build and run in simulator
./build-ios.sh simulator

# Or use Xcode directly
open Package.swift
# Select: CpdbiOS scheme → iPhone 15 Pro Simulator → Press ⌘R
```

### 4. Build for Physical Device

```bash
# Make sure your device is connected and registered
./build-ios.sh list  # List available devices

# Build for your device (replace with your device name)
./build-ios.sh device --device-name "Your iPhone Name"
```

## Files Created

The following files have been created for iOS signing:

1. **`Sources/CpdbiOS/Resources/cpdb-ios.entitlements`**
   - iCloud/CloudKit entitlements
   - Push Notifications
   - App Groups

2. **`Sources/CpdbiOS/Resources/Info.plist`**
   - Bundle identifier: `net.phfactor.cpdb.ios`
   - iOS 17+ minimum version
   - Scene configuration
   - Background modes

3. **`build-ios.sh`**
   - Helper script for command-line builds
   - Handles simulator and device targets

4. **`iOS-SIGNING-SETUP.md`**
   - Comprehensive setup guide
   - Troubleshooting tips

## Common Commands

### Using the Build Script

```bash
# Build for simulator
./build-ios.sh simulator

# Build for specific simulator
./build-ios.sh simulator --device-name "iPhone 14 Pro"

# Build for physical device
./build-ios.sh device --device-name "My iPhone" --team-id ABC1234567

# List available devices
./build-ios.sh list
```

### Using Xcode Directly

```bash
# Open in Xcode
open Package.swift

# Then in Xcode:
# 1. Select CpdbiOS scheme
# 2. Select your device/simulator
# 3. Press ⌘R to build and run
```

### Using xcodebuild Directly

```bash
# Simulator
xcodebuild -scheme CpdbiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  clean build

# Physical Device (replace YOUR_TEAM_ID and YOUR_DEVICE)
xcodebuild -scheme CpdbiOS \
  -destination 'platform=iOS,name=YOUR_DEVICE' \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  clean build
```

## Verifying Your Setup

### Check if App ID is properly configured

```bash
open "https://developer.apple.com/account/resources/identifiers/list"
# Find: net.phfactor.cpdb.ios
# Verify: iCloud (CloudKit) and Push Notifications are enabled
```

### Check installed provisioning profiles

```bash
# List all installed profiles
ls -la ~/Library/MobileDevice/Provisioning\ Profiles/

# Check profile details (replace with your profile name)
security cms -D -i ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision
```

### Check device is registered

```bash
# Get your device UDID (connect device first)
system_profiler SPUSBDataType | grep "Serial Number" | grep -v "0x"

# Or use Finder:
# 1. Open Finder
# 2. Select your device in sidebar
# 3. Click the info line below device name until UDID shows
```

## Troubleshooting Quick Fixes

### "No profiles found"
```bash
# Re-download from developer portal
open "https://developer.apple.com/account/resources/profiles/list"
# Download the profile and double-click it to install
```

### "Signing certificate not found"
```bash
# Open Xcode → Settings → Accounts
# Select your Apple ID → Download Manual Profiles
```

### "Device not found"
```bash
# Make sure device is connected and unlocked
./build-ios.sh list

# Enable Developer Mode on iOS 16+ devices:
# Settings → Privacy & Security → Developer Mode → Enable
```

### Xcode can't find your team
```bash
# Open Xcode → Settings → Accounts
# Click + to add your Apple ID
# Select your account → Manage Certificates → + → Apple Development
```

## Testing CloudKit Sync

Once the app is running:

1. **On iOS device:**
   - Make sure you're signed into iCloud
   - Launch the cpdb app
   - It should automatically pull clipboard history from the Mac

2. **Verify sync is working:**
   - Copy something on your Mac
   - Wait ~30 seconds for CloudKit sync
   - Pull to refresh on iOS
   - The new clipboard item should appear

3. **Check sync status:**
   - On Mac: Menu bar → cpdb → About cpdb → iCloud sync tab
   - Shows last sync time and queue depth

## Next Steps

- [ ] Test on simulator
- [ ] Test on physical device
- [ ] Verify CloudKit sync between Mac and iOS
- [ ] Set up app icon for iOS
- [ ] Configure launch screen
- [ ] Add fastlane for automated signing (optional)

## Updating Entitlements

If you need to add more capabilities:

1. Edit `Sources/CpdbiOS/Resources/cpdb-ios.entitlements`
2. Update the App ID in Developer Portal with the new capability
3. Regenerate the provisioning profile
4. Download and install the new profile

## Distribution (TestFlight/App Store)

When ready to distribute:

1. Create an App Store provisioning profile (not Development)
2. Change `aps-environment` to `production` in entitlements
3. Build with Release configuration:
   ```bash
   xcodebuild -scheme CpdbiOS \
     -destination 'generic/platform=iOS' \
     -configuration Release \
     archive
   ```
4. Upload to App Store Connect with Xcode or Transporter

## Resources

- **Detailed Setup Guide**: `iOS-SIGNING-SETUP.md`
- **Apple Developer Portal**: https://developer.apple.com/account
- **CloudKit Dashboard**: https://icloud.developer.apple.com
- **App Store Connect**: https://appstoreconnect.apple.com

## Getting Help

If you encounter issues:

1. Check `iOS-SIGNING-SETUP.md` for detailed troubleshooting
2. Verify all prerequisites are completed
3. Check Xcode's Report Navigator (⌘9) for detailed error messages
4. Review CloudKit Dashboard for container status
5. Check device console logs in Xcode (Window → Devices and Simulators)
