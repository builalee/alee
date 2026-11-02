"use server";

import { revalidatePath } from "next/cache";
import { failed, plainError, succeeded, type ActionResult } from "@/lib/api/errors";
import { getFamily } from "@/lib/api/queries";
import { createClient } from "@/lib/supabase/server";
import { text } from "@/lib/text";

export async function offerTerritory(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const family = await getFamily();
  const fields = ["brandId", "regionId", "distributorId", "type"].map((f) => String(form.get(f) ?? ""));
  if (fields.some((f) => !f)) return failed(text.signup.fillAll);
  const [brandId, regionId, distributorId, type] = fields;

  const supabase = await createClient();
  const { error } = await supabase.rpc("offer_territory", {
    p_brand_id: brandId, p_distributor_id: distributorId, p_segment_id: family?.id,
    p_region_id: regionId, p_type: type,
  });
  if (error) return failed(plainError(error));
  revalidatePath("/seller/distributors");
  return succeeded;
}

/** Accept, decline, end or withdraw. The database decides who may do which. */
export async function respondToTerritory(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const id = String(form.get("id"));
  const move = String(form.get("move"));
  const supabase = await createClient();
  const { error } = move === "end"
    ? await supabase.rpc("end_territory", { p_allocation_id: id })
    : await supabase.rpc("respond_to_territory", { p_allocation_id: id, p_accept: move === "accept" });
  if (error) return failed(plainError(error));
  revalidatePath("/seller/distributors");
  return succeeded;
}
