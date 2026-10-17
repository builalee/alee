/**
 * Runs the saved database checks in tests/database against the Supabase
 * project the CLI is linked to (normally alee-dev).
 *
 * Every check file runs inside a transaction that is always rolled back,
 * so nothing a check creates (test logins, test sellers) is ever kept.
 *
 *   npm run check:db                      every check file
 *   npm run check:db -- accounts          only files whose name contains "accounts"
 *   npm run check:db -- --allow-live      needed when linked to anything but alee-dev
 *
 * Exits with code 1 if any check fails, so it can gate a deploy.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DEV_PROJECT_NAME = "alee-dev";

const root = fileURLToPath(new URL("..", import.meta.url));
const checksDir = path.join(root, "tests", "database");
const helpersFile = path.join(checksDir, "_helpers.sql");
const supabaseCli = path.join(root, "node_modules", "supabase", "dist", "supabase.js");

type LinkedProject = { ref: string; name: string };
type CheckRow = { n: number; test: string; expected: string; got: string; pass: boolean };

function stop(message: string): never {
  console.error(`\n${message}\n`);
  process.exit(1);
}

function linkedProject(): LinkedProject {
  const file = path.join(root, "supabase", ".temp", "linked-project.json");
  try {
    return JSON.parse(readFileSync(file, "utf8")) as LinkedProject;
  } catch {
    stop("The Supabase CLI is not linked to a project. See README.md, \"Set up on a new laptop\".");
  }
}

// A check file must never end the transaction itself, or its test data
// would be kept.
function assertNoTransactionControl(file: string, sql: string): void {
  const code = sql.replace(/--.*$/gm, "");
  if (/\b(commit|rollback|start\s+transaction|end\s+transaction)\b|\bbegin\s*;/i.test(code)) {
    stop(`${file} contains a transaction command (begin/commit/rollback). Remove it: the runner handles this.`);
  }
}

function parseCliOutput(output: string): unknown {
  const start = output.indexOf("{");
  if (start === -1) return null;
  try {
    return JSON.parse(output.slice(start));
  } catch {
    return null;
  }
}

function runCheckFile(file: string, workDir: string): CheckRow[] {
  const body = readFileSync(path.join(checksDir, file), "utf8");
  assertNoTransactionControl(file, body);

  const script = [
    "begin;",
    readFileSync(helpersFile, "utf8"),
    body,
    "select n, test, expected, got, pass from check_results order by n;",
    "rollback;",
  ].join("\n");

  const scriptPath = path.join(workDir, file);
  writeFileSync(scriptPath, script);

  let output: string;
  try {
    output = execFileSync(
      process.execPath,
      [supabaseCli, "db", "query", "--linked", "-f", scriptPath, "-o", "json"],
      { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
  } catch (error) {
    const e = error as { stdout?: string; stderr?: string; message: string };
    const parsed = parseCliOutput(e.stdout ?? "") as { error?: { message?: string } } | null;
    throw new Error(parsed?.error?.message ?? e.stderr?.trim() ?? e.message);
  }

  const parsed = parseCliOutput(output) as { rows?: CheckRow[] } | null;
  if (!parsed?.rows) throw new Error(`Unexpected output from the Supabase CLI:\n${output.slice(0, 1000)}`);
  return parsed.rows;
}

function main(): void {
  const args = process.argv.slice(2);
  const allowLive = args.includes("--allow-live");
  const filters = args.filter((a) => !a.startsWith("--"));

  const project = linkedProject();
  if (project.name !== DEV_PROJECT_NAME && !allowLive) {
    stop(
      `The CLI is linked to "${project.name}" (${project.ref}), not ${DEV_PROJECT_NAME}.\n` +
        `Checks are rolled back, but to run them anywhere except ${DEV_PROJECT_NAME} add --allow-live.`,
    );
  }

  const files = readdirSync(checksDir)
    .filter((f) => f.endsWith(".sql") && !f.startsWith("_"))
    .filter((f) => filters.length === 0 || filters.some((x) => f.includes(x)))
    .sort();
  if (files.length === 0) stop("No check files matched.");

  console.log(`\nChecking ${project.name} (${project.ref}). Every check is rolled back; nothing is kept.\n`);

  const workDir = mkdtempSync(path.join(tmpdir(), "alee-checks-"));
  let passed = 0;
  let failed = 0;

  try {
    for (const file of files) {
      console.log(file);
      let rows: CheckRow[];
      try {
        rows = runCheckFile(file, workDir);
      } catch (error) {
        failed++;
        console.log(`  ✗ The file could not run: ${(error as Error).message}\n`);
        continue;
      }
      for (const row of rows) {
        if (row.pass) {
          passed++;
          console.log(`  ✓ ${row.test}`);
        } else {
          failed++;
          console.log(`  ✗ ${row.test}\n      expected: ${row.expected}\n      got:      ${row.got}`);
        }
      }
      console.log("");
    }
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }

  console.log(failed === 0 ? `All ${passed} checks passed.` : `${failed} FAILED, ${passed} passed.`);
  process.exit(failed === 0 ? 0 : 1);
}

main();
