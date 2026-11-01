"use server";

import { revalidatePath } from "next/cache";
import { failed, plainError, succeeded, type ActionResult } from "@/lib/api/errors";
import { createClient } from "@/lib/supabase/server";

type Decision = "decide_role_request" | "decide_brand" | "decide_brand_claim";

const argumentFor: Record<Decision, string> = {
  decide_role_request: "p_request_id",
  decide_brand: "p_brand_id",
  decide_brand_claim: "p_claim_id",
};

/** One approve or refuse button. The database checks the caller is an admin. */
export async function decide(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const kind = String(form.get("kind")) as Decision;
  if (!(kind in argumentFor)) return failed("");

  const supabase = await createClient();
  const { error } = await supabase.rpc(kind, {
    [argumentFor[kind]]: String(form.get("id")),
    p_approve: form.get("approve") === "yes",
  });
  if (error) return failed(plainError(error));
  revalidatePath("/admin");
  return succeeded;
}
