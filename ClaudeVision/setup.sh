#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# VisionClaude Setup — Interactive installer for the VisionClaude system
# ═══════════════════════════════════════════════════════════════════════

set -e

# ── Colors ──────────────────────────────────────────────────────────────
# Anthropic orange palette
ORANGE='\033[38;2;255;149;0m'
DARK_ORANGE='\033[38;2;204;119;0m'
LIGHT_ORANGE='\033[38;2;255;183;77m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────
print_orange() { echo -e "${ORANGE}$1${RESET}"; }
print_step() { echo -e "\n${ORANGE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; echo -e "${WHITE}  $1${RESET}"; echo -e "${ORANGE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
print_ok() { echo -e "  ${GREEN}✓${RESET} $1"; }
print_fail() { echo -e "  ${RED}✗${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
print_info() { echo -e "  ${CYAN}→${RESET} $1"; }
print_dim() { echo -e "  ${DIM}$1${RESET}"; }

prompt_input() {
    echo -ne "  ${LIGHT_ORANGE}▸${RESET} $1 "
    read -r REPLY
    echo "$REPLY"
}

prompt_confirm() {
    echo -ne "  ${LIGHT_ORANGE}▸${RESET} $1 ${DIM}[Y/n]${RESET} "
    read -r REPLY
    case "$REPLY" in
        [nN][oO]|[nN]) return 1 ;;
        *) return 0 ;;
    esac
}

prompt_secret() {
    echo -ne "  ${LIGHT_ORANGE}▸${RESET} $1 "
    read -rs REPLY
    echo ""
    echo "$REPLY"
}

spin() {
    local pid=$1
    local msg=$2
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local c=${spinstr:i%${#spinstr}:1}
        echo -ne "\r  ${ORANGE}${c}${RESET} ${msg}"
        i=$((i + 1))
        sleep 0.1
    done
    wait "$pid"
    return $?
}

# ── ASCII Logo ──────────────────────────────────────────────────────────
show_logo() {
    echo ""
    echo -e "${ORANGE}       ██╗   ██╗██╗███████╗██╗ ██████╗ ███╗   ██╗${RESET}"
    echo -e "${ORANGE}       ██║   ██║██║██╔════╝██║██╔═══██╗████╗  ██║${RESET}"
    echo -e "${DARK_ORANGE}       ██║   ██║██║███████╗██║██║   ██║██╔██╗ ██║${RESET}"
    echo -e "${DARK_ORANGE}       ╚██╗ ██╔╝██║╚════██║██║██║   ██║██║╚██╗██║${RESET}"
    echo -e "${LIGHT_ORANGE}        ╚████╔╝ ██║███████║██║╚██████╔╝██║ ╚████║${RESET}"
    echo -e "${LIGHT_ORANGE}         ╚═══╝  ╚═╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝${RESET}"
    echo ""
    echo -e "${ORANGE}        ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗${RESET}"
    echo -e "${ORANGE}       ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝${RESET}"
    echo -e "${DARK_ORANGE}       ██║     ██║     ███████║██║   ██║██║  ██║█████╗  ${RESET}"
    echo -e "${DARK_ORANGE}       ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ${RESET}"
    echo -e "${LIGHT_ORANGE}       ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗${RESET}"
    echo -e "${LIGHT_ORANGE}        ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝${RESET}"
    echo ""
    echo -e "${GRAY}       ───────────────────────────────────────────${RESET}"
    echo -e "${WHITE}      Let Claude see the world through your eyes${RESET}"
    echo -e "${GRAY}       ───────────────────────────────────────────${RESET}"
    echo ""
    echo -e "${DIM}            Built by ${LIGHT_ORANGE}@mrdulasolutions${RESET}"
    echo -e "${DIM}            ${CYAN}github.com/mrdulasolutions${RESET}"
    echo ""
    echo -e "${DIM}        This project is not affiliated with, endorsed${RESET}"
    echo -e "${DIM}        by, or officially connected to Anthropic, PBC${RESET}"
    echo -e "${DIM}        or Meta Platforms, Inc. Claude is a trademark${RESET}"
    echo -e "${DIM}        of Anthropic. Meta and Ray-Ban are trademarks${RESET}"
    echo -e "${DIM}        of Meta Platforms, Inc.${RESET}"
    echo ""
}

# ── Welcome ─────────────────────────────────────────────────────────────
show_welcome() {
    echo -e "${ORANGE}  This installer will set up:${RESET}"
    echo ""
    echo -e "  ${WHITE}1.${RESET} ${LIGHT_ORANGE}Claude Gateway Server${RESET} ${DIM}(Node.js — runs on your Mac)${RESET}"
    echo -e "     ${DIM}Connects Claude API + your MCP tools (email, calendar, etc.)${RESET}"
    echo ""
    echo -e "  ${WHITE}2.${RESET} ${LIGHT_ORANGE}VisionClaude iOS App${RESET} ${DIM}(Swift — runs on your iPhone)${RESET}"
    echo -e "     ${DIM}iPhone camera (1080p) or Meta Ray-Ban glasses (720p) → Claude${RESET}"
    echo ""
    echo -e "  ${WHITE}3.${RESET} ${LIGHT_ORANGE}ElevenLabs TTS${RESET} ${DIM}(optional — premium voice responses)${RESET}"
    echo -e "     ${DIM}10 selectable voices with low-latency flash model${RESET}"
    echo ""
    echo -e "${GRAY}  ─────────────────────────────────────────────────────────${RESET}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 1: Check System Dependencies
# ═══════════════════════════════════════════════════════════════════════
check_dependencies() {
    print_step "Step 1/6 — Checking Dependencies"
    echo ""

    local all_good=true

    # macOS
    if [[ "$(uname)" == "Darwin" ]]; then
        print_ok "macOS detected ($(sw_vers -productVersion))"
    else
        print_fail "macOS required — this setup is for Mac only"
        exit 1
    fi

    # Node.js
    if command -v node &>/dev/null; then
        local node_version
        node_version=$(node -v)
        local major
        major=$(echo "$node_version" | sed 's/v//' | cut -d. -f1)
        if (( major >= 18 )); then
            print_ok "Node.js ${node_version}"
        else
            print_fail "Node.js ${node_version} — version 18+ required"
            all_good=false
        fi
    else
        print_fail "Node.js not found"
        print_info "Install: ${CYAN}brew install node${RESET}"
        all_good=false
    fi

    # npm
    if command -v npm &>/dev/null; then
        print_ok "npm $(npm -v)"
    else
        print_fail "npm not found (comes with Node.js)"
        all_good=false
    fi

    # Xcode
    if command -v xcodebuild &>/dev/null; then
        local xcode_version
        xcode_version=$(xcodebuild -version 2>/dev/null | head -1 || echo "Unknown")
        print_ok "Xcode: ${xcode_version}"

        # Check for iOS platform
        if xcodebuild -showsdks 2>/dev/null | grep -q iphoneos; then
            print_ok "iOS SDK available"
        else
            print_warn "iOS SDK not found — download in Xcode → Settings → Platforms"
        fi
    else
        print_warn "Xcode not found — needed only for iOS app"
        print_info "Install from the Mac App Store"
    fi

    # Xcode CLI tools
    if xcode-select -p &>/dev/null; then
        print_ok "Xcode Command Line Tools"
    else
        print_warn "Xcode CLI tools not installed"
        print_info "Install: ${CYAN}xcode-select --install${RESET}"
    fi

    # XcodeGen
    if command -v xcodegen &>/dev/null; then
        print_ok "XcodeGen $(xcodegen --version 2>/dev/null || echo "")"
    else
        print_warn "XcodeGen not found — needed only for iOS app"
        print_info "Install: ${CYAN}brew install xcodegen${RESET}"
    fi

    # Check for Anthropic API key in environment
    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
        print_ok "ANTHROPIC_API_KEY found in environment"
    else
        print_dim "ANTHROPIC_API_KEY not in environment (will prompt later)"
    fi

    echo ""

    if [[ "$all_good" == false ]]; then
        print_fail "Missing required dependencies. Please install them and re-run."
        echo ""

        if ! command -v node &>/dev/null; then
            echo -e "  ${ORANGE}Install Node.js:${RESET}"
            echo -e "    ${CYAN}brew install node${RESET}"
            echo -e "    ${DIM}— or download from https://nodejs.org${RESET}"
            echo ""
        fi

        if prompt_confirm "Install missing dependencies with Homebrew?"; then
            echo ""
            if ! command -v brew &>/dev/null; then
                print_fail "Homebrew not found. Install it first:"
                echo -e "    ${CYAN}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${RESET}"
                exit 1
            fi

            if ! command -v node &>/dev/null; then
                print_info "Installing Node.js..."
                brew install node 2>&1 | tail -1
                print_ok "Node.js installed"
            fi
        else
            exit 1
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 2: Configure API Key
# ═══════════════════════════════════════════════════════════════════════
configure_api_key() {
    print_step "Step 2/6 — Anthropic API Key"
    echo ""

    local api_key=""

    # Check existing .env
    if [[ -f "$SCRIPT_DIR/server/.env" ]]; then
        local existing_key
        existing_key=$(grep "^ANTHROPIC_API_KEY=" "$SCRIPT_DIR/server/.env" 2>/dev/null | cut -d= -f2-)
        if [[ -n "$existing_key" && "$existing_key" != "sk-ant-..." ]]; then
            local masked="${existing_key:0:12}...${existing_key: -4}"
            print_ok "API key found in .env: ${DIM}${masked}${RESET}"
            if prompt_confirm "Keep this API key?"; then
                return 0
            fi
        fi
    fi

    # Check environment
    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
        local masked="${ANTHROPIC_API_KEY:0:12}...${ANTHROPIC_API_KEY: -4}"
        print_ok "API key found in environment: ${DIM}${masked}${RESET}"
        if prompt_confirm "Use this API key?"; then
            api_key="$ANTHROPIC_API_KEY"
        fi
    fi

    # Prompt for key
    if [[ -z "$api_key" ]]; then
        echo -e "  ${WHITE}You need an Anthropic API key to use VisionClaude.${RESET}"
        echo -e "  ${DIM}Get one at: ${CYAN}https://console.anthropic.com/settings/keys${RESET}"
        echo ""
        api_key=$(prompt_secret "Enter your Anthropic API key:")

        if [[ -z "$api_key" ]]; then
            print_fail "No API key provided. You can add it later in server/.env"
            api_key="sk-ant-..."
        fi
    fi

    # Validate key format
    if [[ "$api_key" == sk-ant-* ]]; then
        print_ok "API key format looks valid"
    elif [[ "$api_key" != "sk-ant-..." ]]; then
        print_warn "API key doesn't start with 'sk-ant-' — double-check it"
    fi

    # Write .env
    cat > "$SCRIPT_DIR/server/.env" << EOF
ANTHROPIC_API_KEY=${api_key}
PORT=18790
EOF

    print_ok "API key saved to server/.env"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 3: Configure ElevenLabs TTS (Optional)
# ═══════════════════════════════════════════════════════════════════════
configure_elevenlabs() {
    print_step "Step 3/6 — ElevenLabs Voice (Optional)"
    echo ""

    echo -e "  ${ORANGE}ElevenLabs provides premium text-to-speech voices.${RESET}"
    echo -e "  ${DIM}Much more natural than Apple's built-in TTS.${RESET}"
    echo -e "  ${DIM}Free tier: ~10,000 characters/month.${RESET}"
    echo ""
    echo -e "  ${WHITE}Available voices:${RESET}"
    echo ""
    echo -e "    ${LIGHT_ORANGE}Rachel${RESET}  ${DIM}— Calm & warm (female)${RESET}        ${DIM}[default]${RESET}"
    echo -e "    ${LIGHT_ORANGE}Drew${RESET}    ${DIM}— Well-rounded (male)${RESET}"
    echo -e "    ${LIGHT_ORANGE}Clyde${RESET}   ${DIM}— Deep & strong (male)${RESET}"
    echo -e "    ${LIGHT_ORANGE}Paul${RESET}    ${DIM}— Ground news (male)${RESET}"
    echo -e "    ${LIGHT_ORANGE}Domi${RESET}    ${DIM}— Assertive (female)${RESET}"
    echo -e "    ${LIGHT_ORANGE}Dave${RESET}    ${DIM}— British conversational (male)${RESET}"
    echo -e "    ${LIGHT_ORANGE}Fin${RESET}     ${DIM}— Irish (male)${RESET}"
    echo -e "    ${LIGHT_ORANGE}Sarah${RESET}   ${DIM}— Soft & young (female)${RESET}"
    echo -e "    ${LIGHT_ORANGE}Antoni${RESET}  ${DIM}— Well-rounded (male)${RESET}"
    echo -e "    ${LIGHT_ORANGE}Elli${RESET}    ${DIM}— Young & emotional (female)${RESET}"
    echo ""
    echo -e "  ${DIM}Get a key at: ${CYAN}https://elevenlabs.io/app/settings/api-keys${RESET}"
    echo ""

    if prompt_confirm "Add an ElevenLabs API key for premium voice?"; then
        local eleven_key
        eleven_key=$(prompt_secret "Enter your ElevenLabs API key:")
        if [[ -n "$eleven_key" ]]; then
            print_ok "ElevenLabs key received"
            echo ""
            echo -e "  ${WHITE}Enter your key in the iOS app:${RESET}"
            echo -e "  ${DIM}Settings → Voice → ElevenLabs Key → paste key${RESET}"
            echo -e "  ${DIM}Then select your preferred voice from the picker.${RESET}"
            echo ""
            echo -e "  ${DIM}Using ${LIGHT_ORANGE}eleven_flash_v2_5${RESET} ${DIM}model for low-latency responses.${RESET}"
            echo -e "  ${DIM}Voice + settings persist between app launches.${RESET}"
        fi
    else
        print_dim "Skipped — the app will use Apple's built-in TTS"
        print_dim "You can add ElevenLabs later in the iOS app Settings → Voice"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 4: Build Gateway Server
# ═══════════════════════════════════════════════════════════════════════
build_server() {
    print_step "Step 4/6 — Building Gateway Server"
    echo ""

    cd "$SCRIPT_DIR/server"

    # Install dependencies
    print_info "Installing npm dependencies..."
    npm install --silent 2>&1 | tail -1 &
    spin $! "Installing dependencies..."
    echo -e "\r  ${GREEN}✓${RESET} Dependencies installed              "

    # Build TypeScript
    print_info "Compiling TypeScript..."
    npx tsc 2>&1 &
    spin $! "Compiling TypeScript..."
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo -e "\r  ${GREEN}✓${RESET} TypeScript compiled successfully    "
    else
        echo -e "\r  ${RED}✗${RESET} TypeScript compilation failed       "
        echo ""
        print_fail "Build failed. Run manually to see errors:"
        echo -e "    ${CYAN}cd server && npx tsc${RESET}"
        exit 1
    fi

    # Check MCP config
    local mcp_config="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
    if [[ -f "$mcp_config" ]]; then
        local server_count
        server_count=$(python3 -c "import json; d=json.load(open('$mcp_config')); print(len(d.get('mcpServers',{})))" 2>/dev/null || echo "0")
        print_ok "Found Claude Desktop config with ${server_count} MCP server(s)"
        print_dim "These MCP tools will be available through VisionClaude"
    else
        print_warn "No Claude Desktop config found — gateway will work without MCP tools"
        print_dim "MCP servers can be added later via Claude Desktop settings"
    fi

    echo ""
    print_ok "Gateway server built successfully"

    cd "$SCRIPT_DIR"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 5: Build iOS App (Optional)
# ═══════════════════════════════════════════════════════════════════════
build_ios() {
    print_step "Step 5/6 — iOS App Setup"
    echo ""

    if ! command -v xcodebuild &>/dev/null; then
        print_warn "Xcode not installed — skipping iOS build"
        print_info "Install Xcode from the App Store to build the iOS app"
        return 0
    fi

    if ! prompt_confirm "Set up the iOS app? (requires Xcode)"; then
        print_dim "Skipping iOS setup. You can build it later in Xcode."
        return 0
    fi

    echo ""

    # Check XcodeGen
    if ! command -v xcodegen &>/dev/null; then
        print_info "XcodeGen needed to generate the Xcode project"
        if prompt_confirm "Install XcodeGen via Homebrew?"; then
            brew install xcodegen 2>&1 | tail -1 &
            spin $! "Installing XcodeGen..."
            echo -e "\r  ${GREEN}✓${RESET} XcodeGen installed                  "
        else
            print_warn "Skipping — run 'brew install xcodegen' later"
            return 0
        fi
    else
        print_ok "XcodeGen found"
    fi

    # Generate Xcode project
    cd "$SCRIPT_DIR/ios"
    print_info "Generating Xcode project..."
    xcodegen generate 2>&1 | tail -1
    print_ok "Xcode project generated"

    # Get hostname for default config
    local hostname
    hostname=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
    print_ok "Your Mac hostname: ${WHITE}${hostname}.local${RESET}"
    print_dim "The iOS app will connect to this hostname by default"

    # Update the default hostname in ClaudeConfig.swift
    if [[ -f "$SCRIPT_DIR/ios/ClaudeVision/Models/ClaudeConfig.swift" ]]; then
        sed -i '' "s/MR-DULA-SOLUTIONS.local/${hostname}.local/g" "$SCRIPT_DIR/ios/ClaudeVision/Models/ClaudeConfig.swift" 2>/dev/null || true
        print_ok "Updated default gateway host in ClaudeConfig.swift"
    fi

    echo ""
    echo -e "  ${ORANGE}╔═══════════════════════════════════════════════════════╗${RESET}"
    echo -e "  ${ORANGE}║${RESET}  ${WHITE}iOS App — Build & Deploy${RESET}                            ${ORANGE}║${RESET}"
    echo -e "  ${ORANGE}╚═══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${WHITE}1.${RESET} Open the project in Xcode:"
    echo -e "     ${CYAN}open \"$SCRIPT_DIR/ios/ClaudeVision.xcodeproj\"${RESET}"
    echo ""
    echo -e "  ${WHITE}2.${RESET} Select your Apple Developer Team:"
    echo -e "     ${DIM}Click the ${LIGHT_ORANGE}ClaudeVision${RESET} ${DIM}project in the left sidebar${RESET}"
    echo -e "     ${DIM}→ \"Signing & Capabilities\" tab → pick your Team${RESET}"
    echo ""
    echo -e "  ${WHITE}3.${RESET} Connect your iPhone via USB cable:"
    echo -e "     ${DIM}Plug in your iPhone → tap \"Trust\" if prompted on the phone${RESET}"
    echo -e "     ${DIM}In Xcode's top toolbar, click the device dropdown (next to ▶)${RESET}"
    echo -e "     ${DIM}→ Select your iPhone under \"Connected Devices\"${RESET}"
    echo -e "     ${DIM}   ${YELLOW}⚠${RESET} ${DIM}Do NOT use a Simulator — camera/mic/glasses won't work${RESET}"
    echo ""
    echo -e "  ${WHITE}4.${RESET} Build and run: ${LIGHT_ORANGE}⌘R${RESET}"
    echo -e "     ${DIM}First time: Xcode will download the Meta DAT SDK (~30s)${RESET}"
    echo -e "     ${DIM}and may take a moment to prepare your device${RESET}"
    echo ""
    echo -e "  ${WHITE}5.${RESET} Trust the app on your iPhone ${DIM}(first time only):${RESET}"
    echo -e "     ${DIM}If you see \"Untrusted Developer\" — go to:${RESET}"
    echo -e "     ${DIM}iPhone Settings → General → VPN & Device Management${RESET}"
    echo -e "     ${DIM}→ Tap your developer profile → \"Trust\"${RESET}"
    echo ""
    echo -e "  ${WHITE}6.${RESET} Grant permissions when prompted:"
    echo -e "     ${DIM}Camera, Microphone, Speech Recognition, Local Network,${RESET}"
    echo -e "     ${DIM}Bluetooth (for Meta Ray-Ban glasses)${RESET}"
    echo ""

    echo -e "  ${GRAY}─────────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -e "  ${ORANGE}Camera Specs:${RESET}"
    echo -e "    ${WHITE}iPhone${RESET}          ${DIM}1920×1080 (1080p) @ 30fps${RESET}"
    echo -e "    ${WHITE}Meta Ray-Ban${RESET}    ${DIM}1280×720  (720p)  @ 30fps${RESET}"
    echo ""

    # Ray-Ban setup
    if prompt_confirm "Do you have Meta Ray-Ban Smart Glasses?"; then
        echo ""
        echo -e "  ${ORANGE}╔═══════════════════════════════════════════════════════╗${RESET}"
        echo -e "  ${ORANGE}║${RESET}  ${WHITE}Meta Ray-Ban — Developer Mode Setup${RESET}               ${ORANGE}║${RESET}"
        echo -e "  ${ORANGE}╚═══════════════════════════════════════════════════════╝${RESET}"
        echo ""
        echo -e "  ${WHITE}Prerequisites:${RESET}"
        echo -e "     ${DIM}• Meta Ray-Ban Smart Glasses (any model)${RESET}"
        echo -e "     ${DIM}• Meta AI app on your iPhone${RESET}"
        echo -e "     ${DIM}• Meta Developer Account${RESET}"
        echo -e "       ${CYAN}https://developers.meta.com${RESET}"
        echo ""
        echo -e "  ${WHITE}Pairing & Developer Mode:${RESET}"
        echo ""
        echo -e "  ${WHITE}Step 1:${RESET} Open the ${LIGHT_ORANGE}Meta AI${RESET} app on your iPhone"
        echo -e "  ${WHITE}Step 2:${RESET} Sign in with your Meta account"
        echo -e "  ${WHITE}Step 3:${RESET} Pair your glasses via Bluetooth (if not already)"
        echo -e "  ${WHITE}Step 4:${RESET} Go to ${LIGHT_ORANGE}Settings → your glasses → Developer Mode${RESET}"
        echo -e "  ${WHITE}Step 5:${RESET} Toggle ${LIGHT_ORANGE}Developer Mode ON${RESET}"
        echo -e "  ${WHITE}Step 6:${RESET} Restart your glasses:"
        echo -e "         ${DIM}• Hold the button for 15 seconds to power off${RESET}"
        echo -e "         ${DIM}• Press the button to power back on${RESET}"
        echo ""
        echo -e "  ${WHITE}Meta Developer Portal Setup:${RESET}"
        echo ""
        echo -e "  ${WHITE}Step 7:${RESET} Go to ${CYAN}https://developers.meta.com${RESET}"
        echo -e "  ${WHITE}Step 8:${RESET} Create a new app → select \"Wearables\""
        echo -e "  ${WHITE}Step 9:${RESET} In App Configuration → iOS → Add app details:"
        echo -e "         ${DIM}• Team ID: your Apple Developer Team ID${RESET}"
        echo -e "         ${DIM}• Bundle ID: ${LIGHT_ORANGE}com.claudevision.app${RESET}"
        echo -e "         ${DIM}• Universal link: leave blank${RESET}"
        echo -e "  ${WHITE}Step 10:${RESET} Create a version and assign to a release channel"
        echo ""
        echo -e "  ${WHITE}In VisionClaude:${RESET}"
        echo ""
        echo -e "  ${WHITE}Step 11:${RESET} Open VisionClaude → Settings → ${LIGHT_ORANGE}Connect Glasses via Meta AI${RESET}"
        echo -e "  ${WHITE}Step 12:${RESET} Approve the connection in Meta AI when prompted"
        echo -e "  ${WHITE}Step 13:${RESET} Switch camera source to ${LIGHT_ORANGE}Meta Ray-Ban${RESET}"
        echo -e "         ${DIM}You should see the live video feed from your glasses${RESET}"
        echo ""
        echo -e "  ${GRAY}─────────────────────────────────────────────────────────${RESET}"
        echo ""
        echo -e "  ${YELLOW}⚠${RESET}  ${WHITE}Meta Wearables Developer Terms${RESET}"
        echo ""
        echo -e "     ${DIM}By using the Wearables Device Access Toolkit, you agree to:${RESET}"
        echo ""
        echo -e "     ${DIM}• Meta Wearables Developer Terms${RESET}"
        echo -e "       ${CYAN}https://wearables.developer.meta.com/terms${RESET}"
        echo ""
        echo -e "     ${DIM}• Acceptable Use Policy${RESET}"
        echo -e "       ${CYAN}https://wearables.developer.meta.com/acceptable-use-policy${RESET}"
        echo ""
        echo -e "     ${DIM}By enabling Meta integrations, including through this SDK,${RESET}"
        echo -e "     ${DIM}Meta may collect information about how users' Meta devices${RESET}"
        echo -e "     ${DIM}communicate with your app. VisionClaude opts out of analytics${RESET}"
        echo -e "     ${DIM}by default via Info.plist (MWDAT → Analytics → OptOut = YES).${RESET}"
        echo ""
    fi

    cd "$SCRIPT_DIR"
}

# ═══════════════════════════════════════════════════════════════════════
# STEP 6: Final Summary
# ═══════════════════════════════════════════════════════════════════════
show_summary() {
    print_step "Step 6/6 — Setup Complete!"
    echo ""

    local hostname
    hostname=$(scutil --get LocalHostName 2>/dev/null || hostname -s)

    echo -e "  ${GREEN}╔═══════════════════════════════════════════════════════╗${RESET}"
    echo -e "  ${GREEN}║${RESET}  ${WHITE}VisionClaude is ready to go!${RESET}                         ${GREEN}║${RESET}"
    echo -e "  ${GREEN}╚═══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${ORANGE}Start the gateway server:${RESET}"
    echo ""
    echo -e "    ${CYAN}cd \"$(pwd)/server\" && npm start${RESET}"
    echo ""
    echo -e "  ${ORANGE}Or use the quick-start command:${RESET}"
    echo ""
    echo -e "    ${CYAN}./start.sh${RESET}"
    echo ""
    echo -e "  ${GRAY}─────────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -e "  ${ORANGE}Endpoints:${RESET}"
    echo -e "    ${WHITE}Health${RESET}  ${CYAN}http://${hostname}.local:18790/health${RESET}"
    echo -e "    ${WHITE}Tools${RESET}   ${CYAN}http://${hostname}.local:18790/tools${RESET}"
    echo -e "    ${WHITE}Chat${RESET}    ${CYAN}POST http://${hostname}.local:18790/chat${RESET}"
    echo ""
    echo -e "  ${ORANGE}Test it:${RESET}"
    echo -e "    ${CYAN}curl -s http://localhost:18790/health | python3 -m json.tool${RESET}"
    echo ""
    echo -e "  ${GRAY}─────────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -e "  ${ORANGE}Architecture:${RESET}"
    echo ""
    echo -e "    ${DIM}iPhone (1080p)${RESET}   ${ORANGE}╲${RESET}"
    echo -e "    ${DIM}  or${RESET}              ${ORANGE}→${RESET}  ${DIM}Gateway Server${RESET}  ${ORANGE}→${RESET}  ${DIM}Claude API${RESET}"
    echo -e "    ${DIM}Ray-Ban (720p)${RESET}   ${ORANGE}╱${RESET}  ${DIM}  (your Mac)${RESET}      ${ORANGE}→${RESET}  ${DIM}MCP Tools${RESET}"
    echo -e "    ${DIM}Your Voice${RESET}        ${ORANGE}→${RESET}  ${DIM}               ${RESET}  ${ORANGE}←${RESET}  ${DIM}(email, etc.)${RESET}"
    echo -e "    ${DIM}ElevenLabs TTS${RESET}   ${ORANGE}←${RESET}  ${DIM}Claude Reply${RESET}"
    echo ""
    echo -e "  ${GRAY}─────────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -e "  ${ORANGE}MCP Tool Sharing:${RESET}"
    echo -e "    ${DIM}VisionClaude auto-discovers MCP servers from your${RESET}"
    echo -e "    ${DIM}Claude Desktop config. Add servers in Claude Desktop${RESET}"
    echo -e "    ${DIM}→ restart the gateway → they appear in VisionClaude.${RESET}"
    echo ""
    echo -e "  ${GRAY}─────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${DIM}  Built by ${LIGHT_ORANGE}@mrdulasolutions${RESET}  ${DIM}•${RESET}  ${DIM}${CYAN}github.com/mrdulasolutions/visionclaude${RESET}"
    echo -e "  ${DIM}  Not affiliated with or endorsed by Anthropic or Meta.${RESET}"
    echo -e "  ${GRAY}─────────────────────────────────────────────────────────${RESET}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# Create quick-start script
# ═══════════════════════════════════════════════════════════════════════
create_start_script() {
    cat > "$SCRIPT_DIR/start.sh" << 'STARTEOF'
#!/bin/bash
ORANGE='\033[38;2;255;149;0m'
WHITE='\033[1;37m'
RESET='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo -e "${ORANGE}  ▸ Starting VisionClaude Gateway...${RESET}"
echo ""

cd "$SCRIPT_DIR/server"

if [[ ! -d "node_modules" ]]; then
    echo -e "${WHITE}  Installing dependencies...${RESET}"
    npm install --silent
fi

if [[ ! -d "dist" ]]; then
    echo -e "${WHITE}  Building...${RESET}"
    npx tsc
fi

npm start
STARTEOF
    chmod +x "$SCRIPT_DIR/start.sh"
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════
main() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    clear
    show_logo
    show_welcome

    if ! prompt_confirm "Ready to begin setup?"; then
        echo ""
        print_dim "Setup cancelled. Run again when ready."
        echo ""
        exit 0
    fi

    check_dependencies
    configure_api_key
    configure_elevenlabs
    build_server
    build_ios
    create_start_script
    show_summary
}

main "$@"
