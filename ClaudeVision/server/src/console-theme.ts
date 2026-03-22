// ── Anthropic Orange Console Theme ──────────────────────────────────
// Terminal colors matching the VisionClaude brand

const ORANGE = "\x1b[38;2;255;149;0m";
const DARK_ORANGE = "\x1b[38;2;204;119;0m";
const LIGHT_ORANGE = "\x1b[38;2;255;183;77m";
const WHITE = "\x1b[1;37m";
const GRAY = "\x1b[90m";
const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const RESET = "\x1b[0m";

export const c = {
  orange: (text: string) => `${ORANGE}${text}${RESET}`,
  darkOrange: (text: string) => `${DARK_ORANGE}${text}${RESET}`,
  lightOrange: (text: string) => `${LIGHT_ORANGE}${text}${RESET}`,
  white: (text: string) => `${WHITE}${text}${RESET}`,
  gray: (text: string) => `${GRAY}${text}${RESET}`,
  green: (text: string) => `${GREEN}${text}${RESET}`,
  red: (text: string) => `${RED}${text}${RESET}`,
  yellow: (text: string) => `${YELLOW}${text}${RESET}`,
  cyan: (text: string) => `${CYAN}${text}${RESET}`,
  dim: (text: string) => `${DIM}${text}${RESET}`,
  bold: (text: string) => `${BOLD}${text}${RESET}`,

  // Semantic helpers
  success: (text: string) => `${GREEN}${text}${RESET}`,
  error: (text: string) => `${RED}${text}${RESET}`,
  warn: (text: string) => `${YELLOW}${text}${RESET}`,
  info: (text: string) => `${CYAN}${text}${RESET}`,
  label: (text: string) => `${ORANGE}${text}${RESET}`,
  value: (text: string) => `${LIGHT_ORANGE}${text}${RESET}`,
  url: (text: string) => `${CYAN}${text}${RESET}`,
};

export function showBanner(): void {
  const lines = [
    "",
    `${ORANGE}   ██╗   ██╗██╗███████╗██╗ ██████╗ ███╗   ██╗${RESET}`,
    `${ORANGE}   ██║   ██║██║██╔════╝██║██╔═══██╗████╗  ██║${RESET}`,
    `${DARK_ORANGE}   ██║   ██║██║███████╗██║██║   ██║██╔██╗ ██║${RESET}`,
    `${DARK_ORANGE}   ╚██╗ ██╔╝██║╚════██║██║██║   ██║██║╚██╗██║${RESET}`,
    `${LIGHT_ORANGE}    ╚████╔╝ ██║███████║██║╚██████╔╝██║ ╚████║${RESET}`,
    `${LIGHT_ORANGE}     ╚═══╝  ╚═╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝${RESET}`,
    "",
    `${ORANGE}    ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗${RESET}`,
    `${ORANGE}   ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝${RESET}`,
    `${DARK_ORANGE}   ██║     ██║     ███████║██║   ██║██║  ██║█████╗  ${RESET}`,
    `${DARK_ORANGE}   ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ${RESET}`,
    `${LIGHT_ORANGE}   ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗${RESET}`,
    `${LIGHT_ORANGE}    ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝${RESET}`,
    "",
    `${GRAY}   ─────────────────────────────────────────────${RESET}`,
    `${WHITE}    Let Claude see the world through your eyes${RESET}`,
    `${GRAY}   ─────────────────────────────────────────────${RESET}`,
    `${DIM}         github.com/mrdulasolutions/visionclaude${RESET}`,
    "",
  ];

  for (const line of lines) {
    console.log(line);
  }
}

export function showServerInfo(
  port: number,
  mcpCount: number,
  toolCount: number,
  skillCount: number
): void {

  console.log("");
  console.log(
    `${ORANGE}   ┌─────────────────────────────────────────────┐${RESET}`
  );
  console.log(
    `${ORANGE}   │${RESET}  ${GREEN}●${RESET} ${WHITE}Gateway Active${RESET}                              ${ORANGE}│${RESET}`
  );
  console.log(
    `${ORANGE}   ├─────────────────────────────────────────────┤${RESET}`
  );
  console.log(
    `${ORANGE}   │${RESET}  ${GRAY}Port${RESET}     ${WHITE}${port}${RESET}                               ${ORANGE}│${RESET}`
  );
  console.log(
    `${ORANGE}   │${RESET}  ${GRAY}MCP${RESET}      ${WHITE}${mcpCount} server(s)${RESET} ${GRAY}→${RESET} ${LIGHT_ORANGE}${toolCount} tool(s)${RESET}        ${ORANGE}│${RESET}`
  );
  console.log(
    `${ORANGE}   │${RESET}  ${GRAY}Skills${RESET}   ${WHITE}${skillCount} loaded${RESET}                        ${ORANGE}│${RESET}`
  );
  console.log(
    `${ORANGE}   ├─────────────────────────────────────────────┤${RESET}`
  );
  console.log(
    `${ORANGE}   │${RESET}  ${CYAN}/health${RESET}  ${DIM}Server status${RESET}                      ${ORANGE}│${RESET}`
  );
  console.log(
    `${ORANGE}   │${RESET}  ${CYAN}/tools${RESET}   ${DIM}List MCP tools${RESET}                     ${ORANGE}│${RESET}`
  );
  console.log(
    `${ORANGE}   │${RESET}  ${CYAN}/skills${RESET}  ${DIM}List loaded skills${RESET}                 ${ORANGE}│${RESET}`
  );
  console.log(
    `${ORANGE}   │${RESET}  ${CYAN}POST /chat${RESET} ${DIM}Send message + image${RESET}             ${ORANGE}│${RESET}`
  );
  console.log(
    `${ORANGE}   └─────────────────────────────────────────────┘${RESET}`
  );
  console.log("");
}
