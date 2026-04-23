# iOS App Signing Setup Checklist

Use this checklist to track your progress setting up code signing for CpdbiOS.

## Apple Developer Portal Setup

### App Identifier Configuration
- [ ] Logged into Apple Developer Portal (https://developer.apple.com/account)
- [ ] Created App ID: `net.phfactor.cpdb.ios`
- [ ] Enabled **iCloud** capability
  - [ ] Selected CloudKit
  - [ ] Configured container: `iCloud.net.phfactor.cpdb`
- [ ] Enabled **Push Notifications** capability
- [ ] Enabled **App Groups** capability (optional but recommended)
  - [ ] Configured group: `group.net.phfactor.cpdb`

### Device Registration (For Physical Device Testing)
- [ ] Connected iOS device to Mac
- [ ] Obtained device UDID (via Finder or system_profiler)
- [ ] Registered device in Apple Developer Portal
- [ ] Device name: ___________________________
- [ ] Device UDID: ___________________________

### Provisioning Profile
- [ ] Created iOS App Development provisioning profile
- [ ] Selected App ID: `net.phfactor.cpdb.ios`
- [ ] Included development certificate
- [ ] Included registered device(s)
- [ ] Downloaded provisioning profile
- [ ] Profile name: ___________________________
- [ ] Installed profile (double-click or copy to ~/Library/MobileDevice/Provisioning Profiles/)

## Development Environment

### Xcode Configuration
- [ ] Xcode installed (version ___________)
- [ ] Opened Xcode → Settings → Accounts
- [ ] Added Apple ID to Xcode
- [ ] Verified Team ID: ___________________________
- [ ] Downloaded manual profiles in Xcode (if needed)

### Project Files
- [ ] Reviewed `Sources/CpdbiOS/Resources/cpdb-ios.entitlements`
  - [ ] iCloud container matches: `iCloud.net.phfactor.cpdb`
  - [ ] Push notification environment set (development/production)
  - [ ] App group configured (if using)
- [ ] Reviewed `Sources/CpdbiOS/Resources/Info.plist`
  - [ ] Bundle ID correct: `net.phfactor.cpdb.ios`
  - [ ] Version matches Version.swift
  - [ ] Minimum iOS version: 17.0

### Build Scripts
- [ ] Made build-ios.sh executable: `chmod +x build-ios.sh`
- [ ] Tested script: `./build-ios.sh list`
- [ ] Can see available devices and simulators

## Building & Testing

### Simulator Build (No Signing Required)
- [ ] Ran: `./build-ios.sh simulator`
- [ ] Build succeeded
- [ ] OR: Opened in Xcode with simulator destination
- [ ] App launches in simulator
- [ ] App UI appears correctly

### Physical Device Build (Requires Signing)
- [ ] Device connected and unlocked
- [ ] Developer Mode enabled on device (iOS 16+)
  - Settings → Privacy & Security → Developer Mode
- [ ] Ran: `./build-ios.sh device --device-name "YOUR_DEVICE"`
- [ ] Build succeeded
- [ ] App installed on device
- [ ] App launches on device

### Signing Verification
- [ ] Checked signature: `codesign -dv /path/to/CpdbiOS.app`
- [ ] Verified entitlements: `codesign -d --entitlements :- /path/to/CpdbiOS.app`
- [ ] All required entitlements present:
  - [ ] com.apple.developer.icloud-container-identifiers
  - [ ] com.apple.developer.icloud-services (CloudKit)
  - [ ] aps-environment
  - [ ] keychain-access-groups

## CloudKit Integration Testing

### iCloud Setup
- [ ] Signed into iCloud on iOS device
- [ ] Same iCloud account as development Mac
- [ ] iCloud Drive enabled on device

### CloudKit Container
- [ ] Opened CloudKit Dashboard: https://icloud.developer.apple.com
- [ ] Found container: `iCloud.net.phfactor.cpdb`
- [ ] Verified container is active
- [ ] Checked schema exists (from Mac app)

### Sync Testing
- [ ] Mac app installed and running
- [ ] Mac has clipboard history entries
- [ ] Mac app shows CloudKit sync active (About → iCloud)
- [ ] iOS app launches without errors
- [ ] iOS app shows "Loading..." or similar on first launch
- [ ] iOS app receives clipboard entries from Mac
- [ ] Pull-to-refresh works on iOS
- [ ] New Mac clipboard entries sync to iOS (within ~30 seconds)

## Troubleshooting Log

Use this section to track any issues encountered:

### Issue 1
Date: _______________
Error: _________________________________________________________________
Solution: ______________________________________________________________

### Issue 2
Date: _______________
Error: _________________________________________________________________
Solution: ______________________________________________________________

### Issue 3
Date: _______________
Error: _________________________________________________________________
Solution: ______________________________________________________________

## Additional Notes

___________________________________________________________________________
___________________________________________________________________________
___________________________________________________________________________
___________________________________________________________________________

## Sign-off

Setup completed by: ___________________________ Date: _______________

Tested devices:
- Simulator: _______________________________________________________
- Physical: ________________________________________________________

Known limitations:
- [ ] No push-to-Mac functionality yet
- [ ] Plain-text clipboard copy only (no multi-flavor)
- [ ] No background fetch (manual pull-to-refresh)

## Next Steps

- [ ] Test on multiple iOS devices
- [ ] Create app icon for iOS
- [ ] Customize launch screen
- [ ] Consider TestFlight distribution for beta testing
- [ ] Plan for App Store submission (if applicable)
- [ ] Set up fastlane for automated builds (optional)
- [ ] Add CI/CD for iOS builds (optional)

---

**Resources:**
- Quick Start: `iOS-QUICK-START.md`
- Detailed Setup: `iOS-SIGNING-SETUP.md`
- Build Script: `build-ios.sh`
- Apple Developer Portal: https://developer.apple.com/account
- CloudKit Dashboard: https://icloud.developer.apple.com
