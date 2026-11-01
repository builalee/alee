/**
 * ALEE safety check. Runs before every Bash and PowerShell command and every
 * file edit Claude Code is about to make (see .claude/settings.json,
 * "hooks"), and refuses owner-only actions outright (CLAUDE.md section 3A):
 *
 *   - anything naming the key files .env.local / .env.local.live-backup;
 *   - any change to files in this project's .claude folder (this check and
 *     the settings that switch it on);
 *   - git push, in any form;
 *   - supabase link / unlink;
 *   - any supabase command while the linked project is not alee-dev, or when
 *     the linked project cannot be read;
 *   - any supabase command using --db-url, or naming a project other than
 *     alee-dev; any command naming the live project, or --allow-live.
 *
 * Refusals use exit code 2, which works in every permission mode, including
 * auto mode, where "ask" rules are settled without asking the owner.
 * Anything unexpected also refuses: this check fails closed.
 */
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

const ALEE_DEV = "rgbveznorkvvukrgxrag";
const LIVE = "ljktpaimmdxxhitafjby";
const KEYS_MESSAGE = "Blocked: .env files hold keys. Ask the owner.";
const OWNER_MESSAGE = "Blocked: owner-only action. Give the owner the exact steps.";

function refuse(message: string): never {
  process.stderr.write(message + "\n");
  process.exit(2);
}

type Input = { tool_name?: string; tool_input?: Record<string, unknown>; cwd?: string };

let input: Input;
try {
  input = JSON.parse(readFileSync(0, "utf8")) as Input;
} catch {
  refuse(OWNER_MESSAGE);
}

const projectDir = path.resolve(process.env.CLAUDE_PROJECT_DIR ?? input.cwd ?? process.cwd());
const tool = input.tool_name ?? "";
const toolInput = input.tool_input ?? {};

// File edits -------------------------------------------------------------------

function isInsideClaudeFolder(file: string): boolean {
  const resolved = path.resolve(projectDir, file).toLowerCase().replaceAll("\\", "/");
  const folder = path.join(projectDir, ".claude").toLowerCase().replaceAll("\\", "/");
  return resolved === folder || resolved.startsWith(folder + "/");
}

if (tool !== "Bash" && tool !== "PowerShell") {
  const file = toolInput.file_path ?? toolInput.notebook_path ?? toolInput.path;
  if (typeof file !== "string" || file === "") refuse(OWNER_MESSAGE);
  if (/\.env\.local/i.test(file)) refuse(KEYS_MESSAGE);
  if (isInsideClaudeFolder(file)) refuse(OWNER_MESSAGE);
  process.exit(0);
}

// Commands ---------------------------------------------------------------------

const command = toolInput.command;
if (typeof command !== "string") refuse(OWNER_MESSAGE);

if (/\.env\.local/i.test(command)) refuse(KEYS_MESSAGE);
if (command.includes(LIVE) || /--allow-live/i.test(command)) refuse(OWNER_MESSAGE);

// Quotes and backslash-escapes removed, so "git 'push'" reads as "git push".
const plain = command.replace(/["'`^]/g, "").replace(/\\(?=[a-z])/gi, "");
// One segment per simple command: split on ; && || | & newlines and $( ( ).
const segments = plain.split(/&&|\|\||[;|&\n\r]|\$\(|[()]/);

const tokensOf = (segment: string) => segment.trim().split(/\s+/).filter(Boolean);
const baseName = (token: string) => token.replaceAll("\\", "/").split("/").pop()!.toLowerCase();

// The subcommand after a program name, skipping its options. Options that
// take a value (git -C dir, git -c key=value, ...) skip that value too.
function subcommandAfter(tokens: string[], at: number, valueOptions: string[]): string | undefined {
  for (let i = at + 1; i < tokens.length; i++) {
    const t = tokens[i].toLowerCase();
    if (!t.startsWith("-")) return t;
    if (valueOptions.includes(t)) i++;
  }
  return undefined;
}

const GIT_VALUE_OPTIONS = ["-c", "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"]
  .map((o) => o.toLowerCase());

function linkedProject(): string | undefined {
  try {
    const refFile = path.join(projectDir, "supabase", ".temp", "project-ref");
    const ref = readFileSync(refFile, "utf8").trim();
    const jsonFile = path.join(projectDir, "supabase", ".temp", "linked-project.json");
    if (existsSync(jsonFile)) {
      const linked = JSON.parse(readFileSync(jsonFile, "utf8")) as { ref?: string };
      if (linked.ref !== ref) return undefined;
    }
    return ref;
  } catch {
    return undefined;
  }
}

// A .claude path in a command may only be read or committed, never changed.
const READ_ONLY = /^(git (add|commit|status|diff|log|show|ls-files|blame)|ls|dir|cat|head|tail|grep|rg|wc|get-content|get-childitem|select-string|test-path)\b/i;

for (const segment of segments) {
  const tokens = tokensOf(segment);
  if (tokens.length === 0) continue;

  // Any mention of ".claude" counts: backslashes were removed above, so a
  // Windows path such as .claude\settings.json reads as ".claudesettings.json".
  if (/\.claude/i.test(segment) && (/>/.test(segment) || !READ_ONLY.test(segment.trim()))) {
    refuse(OWNER_MESSAGE);
  }

  for (let i = 0; i < tokens.length; i++) {
    const name = baseName(tokens[i]);

    if (name === "git" || name === "git.exe") {
      const sub = subcommandAfter(tokens, i, GIT_VALUE_OPTIONS);
      if (sub === "push" || sub === "send-pack") refuse(OWNER_MESSAGE);
    }

    if (/^supabase(\.js|\.exe|\.cmd)?$/.test(name)) {
      const sub = subcommandAfter(tokens, i, ["--workdir", "--profile", "--output", "-o"]);
      if (sub === "link" || sub === "unlink") refuse(OWNER_MESSAGE);
      if (/--db-url/i.test(segment)) refuse(OWNER_MESSAGE);
      const refs = [...segment.matchAll(/--project-ref[=\s]+(\S+)/gi)].map((m) => m[1]);
      if (refs.some((r) => r !== ALEE_DEV)) refuse(OWNER_MESSAGE);
      if (linkedProject() !== ALEE_DEV) refuse(OWNER_MESSAGE);
    }
  }
}

process.exit(0);
