"use server";

import { redirect } from "next/navigation";
import { toLoginPhone } from "@/lib/phone";
import { createClient } from "@/lib/supabase/server";
import { text } from "@/lib/text";

export type LoginState = { phone: string | null; error: string | null };

/** Step 1: the number is checked and a code requested for it. */
export async function requestCode(_state: LoginState, form: FormData): Promise<LoginState> {
  const phone = toLoginPhone(String(form.get("phone") ?? ""));
  if (!phone) return { phone: null, error: text.login.invalidPhone };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithOtp({ phone });
  if (error) {
    const message = error.status === 429 ? text.login.tooManyRequests : text.login.couldNotSend;
    return { phone: null, error: message };
  }
  return { phone, error: null };
}

/** Step 2: the code is checked and the person logged in. */
export async function verifyCode(state: LoginState, form: FormData): Promise<LoginState> {
  const code = String(form.get("code") ?? "").replace(/\D/g, "");
  if (!state.phone) return { phone: null, error: text.login.invalidPhone };
  if (code.length !== 6) return { ...state, error: text.login.invalidCode };

  const supabase = await createClient();
  const { error } = await supabase.auth.verifyOtp({ phone: state.phone, token: code, type: "sms" });
  if (error) {
    const message = error.status === 429 ? text.login.tooManyRequests : text.login.wrongCode;
    return { ...state, error: message };
  }
  redirect("/");
}

export async function logOut(): Promise<void> {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/");
}

/** The logged-in person's login phone, checked with Supabase; null for a visitor. */
export async function currentLoginPhone(): Promise<string | null> {
  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();
  return data.user?.phone ?? null;
}
