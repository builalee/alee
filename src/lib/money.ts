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
