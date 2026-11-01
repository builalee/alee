/**
 * Runs before every Bash and PowerShell command Claude Code is about to run
 * (see .claude/settings.json, "hooks"). Refuses any command that mentions
 * the key files .env.local or .env.local.live-backup, in any letter case.
 * Other names such as .env.example are allowed.
 *
 * Why: the permission rules could not stop the shell's ">" from emptying or
 * overwriting the key files (CLAUDE.md section 3A, "Known gap"). This check
 * looks at the whole command text instead.
 *
 * Exit code 2 refuses the command and shows the message to Claude. Anything
 * unexpected (unreadable input) also refuses: this check fails closed.
 */
import { readFileSync } from "node:fs";

const MESSAGE = "Blocked: .env files hold keys. Ask the owner.";

function refuse(): never {
  process.stderr.write(MESSAGE + "\n");
  process.exit(2);
}

let command: unknown;
try {
  const input = JSON.parse(readFileSync(0, "utf8")) as { tool_input?: { command?: unknown } };
  command = input.tool_input?.command;
} catch {
  refuse();
}

if (typeof command !== "string") refuse();
if (/\.env\.local/i.test(command)) refuse();
process.exit(0);
