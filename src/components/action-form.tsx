"use client";

import { useActionState, type ReactNode } from "react";
import type { ActionResult } from "@/lib/api/errors";
import { text } from "@/lib/text";

type Props = {
  action: (state: ActionResult, form: FormData) => Promise<ActionResult>;
  submit: string;
  secondary?: boolean;
  children?: ReactNode;
};

/** Every form: its fields, its button, and the database's answer in plain words. */
export function ActionForm({ action, submit, secondary, children }: Props) {
  const [state, run, pending] = useActionState(action, { error: null, saved: false });

  return (
    <form action={run} className="flex flex-col gap-3">
      {children}
      {state.error && <p role="alert" className="text-red-700 dark:text-red-400">{state.error}</p>}
      {state.saved && !secondary && <p role="status" className="text-green-700 dark:text-green-400">{text.common.saved}</p>}
      <button type="submit" disabled={pending} className={secondary ? secondaryButton : primaryButton}>
        {pending ? text.common.wait : submit}
      </button>
    </form>
  );
}

const primaryButton = "w-full rounded-lg bg-foreground px-3 py-3 text-lg font-semibold text-background disabled:opacity-50";
const secondaryButton = "w-full rounded-lg border border-current/40 px-3 py-2 font-medium disabled:opacity-50";

/** Zero is one tap, never a typed workaround (CLAUDE.md section 9). */
export function ZeroButton({ inputId, label }: { inputId: string; label: string }) {
  return (
    <button
      type="button"
      className="self-start text-sm underline"
      onClick={() => {
        const input = document.getElementById(inputId) as HTMLInputElement | null;
        if (input) input.value = "0";
      }}
    >
      {label}
    </button>
  );
}
