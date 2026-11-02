/**
 * The one place a typed amount is read. The result stays text so the amount
 * reaches the database exact. "0" is a real value; empty stays empty and is
 * never turned into zero (decision 2.24).
 */
export function readAmount(typed: FormDataEntryValue | null): string | "empty" | "invalid" {
  const value = String(typed ?? "").replace(/[,\s]/g, "");
  if (value === "") return "empty";
  return /^-?[0-9]+(\.[0-9]{1,4})?$/.test(value) ? value : "invalid";
}

// Amounts are added exactly, in ten-thousandths of a rupee, never as floating point.
const SCALE = BigInt(10000);

function toUnits(value: string): bigint | null {
  const match = /^(-?)([0-9]+)(?:\.([0-9]{1,4}))?$/.exec(value.replace(/[,\s]/g, ""));
  if (!match) return null;
  const units = BigInt(match[2]) * SCALE + BigInt((match[3] ?? "").padEnd(4, "0"));
  return match[1] ? -units : units;
}

function fromUnits(units: bigint): string {
  const negative = units < BigInt(0);
  const size = negative ? -units : units;
  const fraction = (size % SCALE).toString().padStart(4, "0").replace(/0+$/, "");
  return `${negative ? "-" : ""}${size / SCALE}${fraction ? `.${fraction}` : ""}`;
}

/** Yesterday's rate moved by an amount ("50000" + "-300" = "49700"). Null if either isn't a number. */
export function addAmounts(a: string, b: string): string | null {
  const x = toUnits(a);
  const y = toUnits(b);
  return x === null || y === null ? null : fromUnits(x + y);
}

/** "₹50,000" or "₹56.50": Indian grouping, paise only when needed, like the database's format_rupees. */
export function formatRupees(amount: string): string {
  const value = Number(amount);
  const digits = Math.round(value * 100) % 100 === 0 ? 0 : 2;
  return `₹${value.toLocaleString("en-IN", { minimumFractionDigits: digits, maximumFractionDigits: digits })}`;
}

/** A difference with its sign: "+₹500", "−₹200", "₹0". */
export function formatSignedRupees(amount: string): string {
  const value = Number(amount);
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  return `${sign}${formatRupees(String(Math.abs(value)))}`;
}
