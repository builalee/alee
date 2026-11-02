"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { failed, plainError, succeeded, type ActionResult } from "@/lib/api/errors";
import { requireAccount } from "@/lib/api/queries";
import { toLoginPhone } from "@/lib/phone";
import { createClient } from "@/lib/supabase/server";
import { text } from "@/lib/text";

const pick = (form: FormData, name: string) => String(form.get(name) ?? "").trim() || null;

/** Adds a customer, or saves changes to one. Only the seller's own book (Row Level Security). */
export async function saveClient(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const me = await requireAccount();
  const typedPhone = pick(form, "phone");
  const phone = typedPhone ? toLoginPhone(typedPhone) : null;
  if (typedPhone && !phone) return failed(text.clients.badPhone);
  const details = {
    name: pick(form, "name") ?? "",
    phone,
    region_id: pick(form, "regionId"),
    client_type: pick(form, "type"),
    note: pick(form, "note"),
  };

  const supabase = await createClient();
  const id = pick(form, "id");
  const { data, error } = id
    ? await supabase.from("clients").update(details).eq("id", id).select("id").single()
    : await supabase.from("clients").insert({ ...details, seller_id: me.id }).select("id").single();
  if (error) return failed(error.code === "23505" ? text.clients.phoneTaken : plainError(error));
  revalidatePath("/clients", "layout");
  if (id) return succeeded;
  redirect(`/clients/${data.id}`);
}

/** A new follow-up for one customer, today or later. */
export async function addFollowUp(_state: ActionResult, form: FormData): Promise<ActionResult> {
  await requireAccount();
  const clientId = pick(form, "clientId");
  const supabase = await createClient();
  const { error } = await supabase.rpc("add_follow_up", {
    p_client_id: clientId, p_due_on: pick(form, "dueOn"), p_note: pick(form, "note"),
  });
  if (error) return failed(plainError(error));
  revalidatePath("/clients", "layout");
  redirect(`/clients/${clientId}`);
}

/** "Done" on one follow-up; then ALEE asks for the next date (decision 11.1). */
export async function closeFollowUp(_state: ActionResult, form: FormData): Promise<ActionResult> {
  await requireAccount();
  const clientId = pick(form, "clientId");
  const supabase = await createClient();
  const { error } = await supabase.rpc("close_follow_up", { p_follow_up_id: pick(form, "followUpId") });
  if (error) return failed(plainError(error));
  revalidatePath("/clients", "layout");
  redirect(`/clients/${clientId}/next?closed=${form.get("closedBefore") ? Number(form.get("closedBefore")) + 1 : 1}`);
}

/** Logs a visit, which closes his due and overdue follow-ups; then asks for the next date. */
export async function logVisit(_state: ActionResult, form: FormData): Promise<ActionResult> {
  await requireAccount();
  const clientId = pick(form, "clientId");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("log_client_activity", {
    p_client_id: clientId, p_kind: "visit", p_note: pick(form, "note"),
  });
  if (error) return failed(plainError(error));
  revalidatePath("/clients", "layout");
  redirect(`/clients/${clientId}/next?closed=${(data as { closed: number }[])[0]?.closed ?? 0}`);
}

/** Logs a tap on Call or WhatsApp. A call closes his due and overdue follow-ups. */
export async function logContact(clientId: string, kind: "call" | "whatsapp"): Promise<{ closed: number } | { error: string }> {
  await requireAccount();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("log_client_activity", { p_client_id: clientId, p_kind: kind });
  if (error) return { error: plainError(error) };
  revalidatePath("/clients", "layout");
  return { closed: (data as { closed: number }[])[0]?.closed ?? 0 };
}
