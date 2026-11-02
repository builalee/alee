/** Dates and times: stored in UTC, always shown in IST (CLAUDE.md section 11). */
const IST = "Asia/Kolkata";

/** A stored closing time ("18:00:00") as an input value ("18:00"). */
export const toTimeInput = (time: string | null): string => (time ?? "").slice(0, 5);

/** "9:15 AM", in IST. */
export const formatTime = (at: string): string =>
  new Date(at).toLocaleTimeString("en-US", { timeZone: IST, hour: "numeric", minute: "2-digit", hour12: true });

/** "02-11-2026", in IST. */
export const formatDate = (at: string): string =>
  new Date(at).toLocaleDateString("en-GB", { timeZone: IST, day: "2-digit", month: "2-digit", year: "numeric" })
    .replaceAll("/", "-");

/** Today's date in India, as a date input value ("2026-11-02"). */
export const todayInIndia = (): string => new Date().toLocaleDateString("en-CA", { timeZone: IST });

/** Whether a stored time falls on today's date in India. */
export const isTodayInIndia = (at: string): boolean => formatDate(at) === formatDate(new Date().toISOString());

/** "9:15 AM" today, "01-11-2026 9:15 AM" on an earlier day. */
export const formatWhen = (at: string, isToday: boolean): string =>
  isToday ? formatTime(at) : `${formatDate(at)} ${formatTime(at)}`;
