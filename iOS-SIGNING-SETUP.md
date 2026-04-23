# iOS App Signing Setup Guide for CpdbiOS

This guide walks you through setting up code signing for the iOS companion app (`CpdbiOS`).

## Prerequisites

- Apple Developer Account (individual or organization)
- Xcode installed on your Mac
- The existing iCloud container `iCloud.net.phfactor.cpdb` (already created for the macOS app)

## Step 1: Register the iOS App Identifier

1. Go to [Apple Developer Portal → Identifiers](https://developer.apple.com/account/resources/identifiers/list)
2. Click the **+** button to create a new identifier
3. Select **App IDs** and click **Continue**
4. Select **App** and click **Continue**
5. Fill in the details:
   - **Description**: `cpdb iOS`
   - **Bundle ID**: Select "Explicit" and enter `net.phfactor.cpdb.ios`
6. Under **Capabilities**, enable:
   - ✅ **iCloud** (click Configure):
     - Select **CloudKit**
     - Choose the existing container: `iCloud.net.phfactor.cpdb`
     - Click **Continue**, then **Save**
   - ✅ **Push Notifications**
   - ✅ **App Groups** (optional, but recommended):
     - Click Configure
     - Add group: `group.net.phfactor.cpdb`
     - Click **Continue**, then **Save**
7. Click **Continue**, then **Register**

## Step 2: Register Your iOS Device(s)

For development/testing on physical devices:

1. Go to [Apple Developer Portal → Devices](https://developer.apple.com/account/resources/devices/list)
2. Click the **+** button
3. Select **iOS, tvOS, watchOS, visionOS**
4. Enter:
   - **Device Name**: `My iPhone` (or whatever you prefer)
   - **Device ID (UDID)**: Connect your device and get the UDID:
     - Open **Finder**, select your device in the sidebar
     - Click on the device info line (below the device name) until UDID appears
     - Right-click → Copy
5. Click **Continue**, then **Register**

## Step 3: Create a Provisioning Profile

1. Go to [Apple Developer Portal → Profiles](https://developer.apple.com/account/resources/profiles/list)
2. Click the **+** button
3. Under **Development**, select **iOS App Development**, click **Continue**
4. Select your app ID: `net.phfactor.cpdb.ios`, click **Continue**
5. Select your development certificate, click **Continue**
6. Select the devices you want to authorize, click **Continue**
7. Name the profile: `cpdb iOS Development`, click **Generate**
8. Download the profile (e.g., `cpdb_iOS_Development.mobileprovision`)

## Step 4: Install the Provisioning Profile

### Option A: Automatic (via Xcode)
1. Double-click the downloaded `.mobileprovision` file
2. Xcode will import it automatically

### Option B: Manual
```bash
# Move to the provisioning profiles directory
cp cpdb_iOS_Development.mobileprovision ~/Library/MobileDevice/Provisioning\ Profiles/
```

## Step 5: Configure Signing in Xcode

1. Open the project in Xcode:
   ```bash
   cd /path/to/cpdb
   open Package.swift
   ```

2. Select the **CpdbiOS** executable scheme from the scheme picker

3. Go to **File → Project Settings** (or **Xcode → Settings → Accounts**)
   - Ensure your Apple ID is added under **Accounts**
   - Select your account and team
   - Click **Download Manual Profiles** if needed

4. In the Project Navigator, select the Package
   - This is tricky with SPM packages! You'll need to configure signing at build time
   
### Xcode Build Settings for SPM

Since this is a Swift Package, signing is configured differently:

1. **Select the CpdbiOS scheme** from the scheme picker
2. **Edit the scheme** (Product → Scheme → Edit Scheme...)
3. Select **Build → Pre-actions** or use command-line xcodebuild with signing parameters

## Step 6: Build with Xcode

The easiest approach for iOS SPM executables:

```bash
# For simulator (no signing needed)
xcodebuild -scheme CpdbiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  clean build

# For physical device
xcodebuild -scheme CpdbiOS \
  -destination 'platform=iOS,name=Your iPhone Name' \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  clean build
```

Replace `YOUR_TEAM_ID` with your 10-character Team ID (find it in Apple Developer Portal).

### Building and Running in Xcode GUI

1. Open the project: `open Package.swift`
2. Select the **CpdbiOS** scheme
3. Select your iOS device or simulator as the destination
4. Press **⌘R** to build and run

If Xcode prompts about signing:
- Choose **Automatically manage signing**
- Select your team from the dropdown
- Xcode will handle the rest

## Step 7: Verify Signing

After a successful build, verify the signature:

```bash
# Find the built app (location varies)
find ~/Library/Developer/Xcode/DerivedData -name "CpdbiOS.app" -type d

# Check the signature
codesign -dv --verbose=4 /path/to/CpdbiOS.app

# Verify entitlements
codesign -d --entitlements :- /path/to/CpdbiOS.app
```

## Troubleshooting

### Error: "No profiles for 'net.phfactor.cpdb.ios' were found"
- Ensure you've downloaded the provisioning profile (Step 3)
- Double-click the `.mobileprovision` file to install it
- Try using `-allowProvisioningUpdates` with xcodebuild

### Error: "Failed to register bundle identifier"
- The bundle ID is already registered in your account
- Go to Developer Portal → Identifiers and verify it exists
- Ensure all capabilities are properly configured

### Error: "Code signing entitlements are not compatible"
- Verify the entitlements in `cpdb-ios.entitlements` match your App ID capabilities
- Specifically check:
  - iCloud container name: `iCloud.net.phfactor.cpdb`
  - Push notification environment: `development` (use `production` for App Store)
  - App group: `group.net.phfactor.cpdb`

### Error: "The executable was signed with invalid entitlements"
- The provisioning profile doesn't include all the entitlements
- Regenerate the provisioning profile after updating capabilities in the App ID

### CloudKit Not Working
- Ensure you're signed into iCloud on your test device
- Check that the container identifier matches exactly: `iCloud.net.phfactor.cpdb`
- Verify the container is enabled in the App ID configuration
- For the first device, CloudKit may take a few minutes to provision

## Distribution Signing (App Store / TestFlight)

When you're ready to distribute:

1. Create a new provisioning profile with **App Store Distribution** (not Development)
2. Change `aps-environment` in entitlements from `development` to `production`
3. Build with:
   ```bash
   xcodebuild -scheme CpdbiOS \
     -destination 'generic/platform=iOS' \
     -configuration Release \
     -derivedDataPath ./build \
     CODE_SIGN_STYLE=Manual \
     PROVISIONING_PROFILE_SPECIFIER="cpdb iOS Distribution" \
     DEVELOPMENT_TEAM=YOUR_TEAM_ID \
     archive
   ```

## Files Created

The following files have been created for iOS signing:

1. **`Sources/CpdbiOS/Resources/cpdb-ios.entitlements`**
   - Declares required capabilities (iCloud, CloudKit, Push Notifications)
   - Must match the capabilities enabled in your App ID

2. **`Sources/CpdbiOS/Resources/Info.plist`**
   - Standard iOS app Info.plist
   - Contains bundle identifier, version info, supported orientations
   - Includes CloudKit background mode configuration

Both files are already excluded from SPM processing in `Package.swift`.

## Next Steps

Once signing is working:

1. Test CloudKit sync between Mac and iOS
2. Verify the app can pull clipboard history
3. Test on multiple devices
4. Consider setting up CI/CD with fastlane for automated signing

## Reference

- [Apple Developer Documentation: App Distribution Guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
- [Configuring iCloud Capabilities](https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app)
- [CloudKit Quick Start](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/Introduction/Introduction.html)
