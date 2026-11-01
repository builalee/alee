"use client";

import { useActionState, useState, type MouseEvent, type ReactNode } from "react";
import type { ActionResult } from "@/lib/api/errors";
import { text } from "@/lib/text";

type Props = {
  action: (state: ActionResult, form: FormData) => Promise<ActionResult>;
  submit: string;
  secondary?: boolean;
  /** The screen opened with this already saved, so there is nothing to save yet. */
  startSaved?: boolean;
  children?: ReactNode;
};

/**
 * Every form: its fields, its button, and the database's answer in plain words.
 * After a save the button stays inactive until something changes: on the rates
 * screen every save writes a new version into history.
 */
export function ActionForm({ action, submit, secondary, startSaved, children }: Props) {
  const [changed, setChanged] = useState(false);
  const [state, run, pending] = useActionState(async (previous: ActionResult, form: FormData) => {
    const result = await action(previous, form);
    if (!result.error) setChanged(false);
    return result;
  }, { error: null, saved: false });

  const isSaved = !secondary && !changed && !state.error && (state.saved || Boolean(startSaved));
  const noteClick = (e: MouseEvent<HTMLFormElement>) => {
    if ((e.target as HTMLElement).closest("[data-change]")) setChanged(true);
  };

  return (
    <form action={run} onChange={() => setChanged(true)} onClick={noteClick} className="flex flex-col gap-3">
      {children}
      {state.error && <p role="alert" className="text-red-700 dark:text-red-400">{state.error}</p>}
      <button
        type="submit"
        disabled={pending || isSaved}
        aria-live="polite"
        className={isSaved ? savedButton : secondary ? secondaryButton : primaryButton}
      >
        {pending ? text.common.wait : isSaved ? text.common.saved : submit}
      </button>
    </form>
  );
}

const primaryButton = "w-full rounded-lg bg-foreground px-3 py-3 text-lg font-semibold text-background disabled:opacity-50";
const secondaryButton = "w-full rounded-lg border border-current/40 px-3 py-2 font-medium disabled:opacity-50";
const savedButton = "w-full rounded-lg border border-current/40 px-3 py-3 text-lg font-semibold text-green-700 dark:text-green-400";
