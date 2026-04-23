#!/bin/bash
# iOS Build Script for CpdbiOS
# 
# This script helps build and run the CpdbiOS app on iOS devices or simulator.
# It handles the signing and device configuration automatically.
#
# Usage:
#   ./build-ios.sh simulator              # Build for simulator
#   ./build-ios.sh device                 # Build for physical device
#   ./build-ios.sh device --device-name "My iPhone"  # Specific device

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCHEME="CpdbiOS"
BUNDLE_ID="net.phfactor.cpdb.ios"

# Parse arguments
TARGET="${1:-simulator}"
DEVICE_NAME=""
TEAM_ID=""

shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --device-name)
            DEVICE_NAME="$2"
            shift 2
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${GREEN}Building CpdbiOS for $TARGET${NC}"

# Function to get available simulators
list_simulators() {
    echo -e "${YELLOW}Available simulators:${NC}"
    xcrun simctl list devices available | grep -E "iPhone|iPad"
}

# Function to get available devices
list_devices() {
    echo -e "${YELLOW}Available physical devices:${NC}"
    xcrun xctrace list devices 2>&1 | grep -E "iPhone|iPad" | grep -v "Simulator"
}

# Function to get team ID from Xcode
get_team_id() {
    if [ -z "$TEAM_ID" ]; then
        # Try to get from Xcode preferences
        TEAM_ID=$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null | \
                  grep -o '[A-Z0-9]\{10\}' | head -n1 || echo "")
    fi
    
    if [ -z "$TEAM_ID" ]; then
        echo -e "${RED}Error: Could not determine Team ID${NC}"
        echo -e "${YELLOW}Please provide it with: --team-id YOUR_TEAM_ID${NC}"
        echo "Find your Team ID at: https://developer.apple.com/account"
        exit 1
    fi
    
    echo "$TEAM_ID"
}

case $TARGET in
    simulator|sim)
        # Build for simulator (no signing needed)
        if [ -z "$DEVICE_NAME" ]; then
            DEVICE_NAME="iPhone 15 Pro"
        fi
        
        echo -e "${GREEN}Building for simulator: $DEVICE_NAME${NC}"
        
        xcodebuild -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
            -configuration Debug \
            clean build
        
        echo -e "${GREEN}✓ Build successful!${NC}"
        echo ""
        echo "To run in Xcode:"
        echo "  1. open Package.swift"
        echo "  2. Select CpdbiOS scheme"
        echo "  3. Select '$DEVICE_NAME' simulator"
        echo "  4. Press ⌘R"
        ;;
        
    device|dev)
        # Build for physical device (requires signing)
        TEAM_ID=$(get_team_id)
        
        echo -e "${GREEN}Using Team ID: $TEAM_ID${NC}"
        
        if [ -z "$DEVICE_NAME" ]; then
            echo ""
            list_devices
            echo ""
            echo -e "${RED}Error: Device name required for physical device build${NC}"
            echo -e "${YELLOW}Specify with: --device-name \"Your Device Name\"${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}Building for device: $DEVICE_NAME${NC}"
        
        xcodebuild -scheme "$SCHEME" \
            -destination "platform=iOS,name=$DEVICE_NAME" \
            -configuration Debug \
            -allowProvisioningUpdates \
            CODE_SIGN_STYLE=Automatic \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
            clean build
        
        echo -e "${GREEN}✓ Build successful!${NC}"
        echo ""
        echo "To install and run:"
        echo "  The app should now be installed on your device"
        echo "  Or open Xcode and press ⌘R to run"
        ;;
        
    list)
        list_simulators
        echo ""
        list_devices
        ;;
        
    *)
        echo -e "${RED}Unknown target: $TARGET${NC}"
        echo ""
        echo "Usage: $0 [simulator|device|list] [options]"
        echo ""
        echo "Targets:"
        echo "  simulator, sim    Build for iOS Simulator (default)"
        echo "  device, dev       Build for physical device"
        echo "  list              List available devices and simulators"
        echo ""
        echo "Options:"
        echo "  --device-name NAME    Specify device/simulator name"
        echo "  --team-id ID          Specify Apple Developer Team ID"
        echo ""
        echo "Examples:"
        echo "  $0 simulator"
        echo "  $0 simulator --device-name \"iPhone 14 Pro\""
        echo "  $0 device --device-name \"Paul's iPhone\""
        echo "  $0 device --device-name \"My iPhone\" --team-id ABC1234567"
        exit 1
        ;;
esac
