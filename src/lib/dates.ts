/** A stored closing time ("18:00:00") as an input value ("18:00"). */
export const toTimeInput = (time: string | null): string => (time ?? "").slice(0, 5);
