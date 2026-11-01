/** The one place an Indian mobile number is checked and written. */

/** A 10-digit Indian mobile, as typed, in +91 form; null if it isn't one. */
export function toLoginPhone(typed: string): string | null {
  const digits = typed.replace(/\D/g, "");
  return /^[6-9][0-9]{9}$/.test(digits) ? `+91${digits}` : null;
}

/** A login phone as shown on screen: +91 90000 00001. */
export function formatPhone(phone: string): string {
  const digits = phone.replace(/\D/g, "").slice(-10);
  return `+91 ${digits.slice(0, 5)} ${digits.slice(5)}`;
}
