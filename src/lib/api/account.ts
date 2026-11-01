"use server";

import { redirect } from "next/navigation";
import { getMe } from "@/lib/api/queries";
import { failed, plainError, type ActionResult } from "@/lib/api/errors";
import { createClient } from "@/lib/supabase/server";
import { text } from "@/lib/text";

const NOTICE_VERSION = "demo-2026-11";

export async function createAccount(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const me = await getMe();
  if (!me) redirect("/login");

  const fullName = String(form.get("fullName") ?? "").trim();
  const firmName = String(form.get("firmName") ?? "").trim();
  const role = String(form.get("role") ?? "");
  const regionId = String(form.get("regionId") ?? "");
  if (!fullName || !role || !regionId) return failed(text.signup.fillAll);
  if (!form.get("terms") || !form.get("privacy")) return failed(text.signup.mustAgree);

  const supabase = await createClient();
  const { error } = await supabase.from("accounts").insert({
    id: me.id,
    full_name: fullName,
    firm_name: firmName || null,
    phone: `+${me.phone.replace(/^\+/, "")}`,
    signup_role: role,
    region_id: regionId,
  });
  if (error) return failed(plainError(error));

  const { error: consentError } = await supabase.from("consents").insert([
    { account_id: me.id, purpose: "terms_of_use", notice_version: NOTICE_VERSION, granted: true },
    { account_id: me.id, purpose: "privacy_notice", notice_version: NOTICE_VERSION, granted: true },
  ]);
  if (consentError) return failed(plainError(consentError));

  redirect("/");
}
