import { text } from "@/lib/text";

export type ActionResult = { error: string | null; saved: boolean };

/**
 * What a person sees when the database refuses. The rules' own refusals are
 * already written in plain words (decision 2.32); anything else is logged for
 * us and shown as a general message.
 */
export function plainError(error: { code?: string; message: string }): string {
  if (error.code === "P0001") return error.message;
  console.error("Database refused:", error.code);
  if (error.code === "42501") return text.common.notAllowed;
  if (error.code === "23505") return text.common.alreadyDone;
  return text.common.somethingWrong;
}

export const failed = (error: string): ActionResult => ({ error, saved: false });
export const succeeded: ActionResult = { error: null, saved: true };
