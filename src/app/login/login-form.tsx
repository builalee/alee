"use client";

import { useActionState, useState } from "react";
import { requestCode, verifyCode, type LoginState } from "@/lib/api/auth";
import { formatPhone } from "@/lib/phone";
import { text } from "@/lib/text";

const start: LoginState = { phone: null, error: null };

const inputStyle = "w-full rounded-lg border border-current/30 bg-transparent px-3 py-3 text-lg";
const buttonStyle = "w-full rounded-lg bg-foreground px-3 py-3 text-lg font-semibold text-background disabled:opacity-50";

export function LoginForm() {
  const [codeRequest, setCodeRequest] = useState<LoginState | null>(null);

  if (codeRequest?.phone) {
    return <CodeStep key={codeRequest.phone} sentTo={codeRequest} onChangeNumber={() => setCodeRequest(null)} />;
  }
  return <PhoneStep onSent={setCodeRequest} />;
}

function PhoneStep({ onSent }: { onSent: (state: LoginState) => void }) {
  const [state, action, pending] = useActionState(async (previous: LoginState, form: FormData) => {
    const next = await requestCode(previous, form);
    if (next.phone) onSent(next);
    return next;
  }, start);

  return (
    <form action={action} className="flex w-full max-w-sm flex-col gap-3">
      <label htmlFor="phone" className="font-medium">{text.login.phoneLabel}</label>
      <div className="flex items-center gap-2">
        <span className="text-lg">{text.login.countryCode}</span>
        <input id="phone" name="phone" type="tel" inputMode="numeric" autoComplete="tel-national"
          maxLength={10} required className={inputStyle} />
      </div>
      {state.error && <p role="alert" className="text-red-700 dark:text-red-400">{state.error}</p>}
      <button type="submit" disabled={pending} className={buttonStyle}>
        {pending ? text.login.sending : text.login.sendCode}
      </button>
    </form>
  );
}

function CodeStep({ sentTo, onChangeNumber }: { sentTo: LoginState; onChangeNumber: () => void }) {
  const [state, action, pending] = useActionState(verifyCode, sentTo);

  return (
    <form action={action} className="flex w-full max-w-sm flex-col gap-3">
      <p>{text.login.codeSentTo} {formatPhone(sentTo.phone!)}</p>
      <label htmlFor="code" className="font-medium">{text.login.codeLabel}</label>
      <input id="code" name="code" type="text" inputMode="numeric" autoComplete="one-time-code"
        maxLength={6} required className={inputStyle} />
      {state.error && <p role="alert" className="text-red-700 dark:text-red-400">{state.error}</p>}
      <button type="submit" disabled={pending} className={buttonStyle}>
        {pending ? text.login.checking : text.login.logIn}
      </button>
      <button type="button" onClick={onChangeNumber} className="py-2 underline">
        {text.login.changeNumber}
      </button>
    </form>
  );
}
