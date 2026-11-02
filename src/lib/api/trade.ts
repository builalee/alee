"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { failed, plainError, type ActionResult } from "@/lib/api/errors";
import { getFamily, requireAccount } from "@/lib/api/queries";
import { readAmount } from "@/lib/money";
import { createClient } from "@/lib/supabase/server";
import { text } from "@/lib/text";

/**
 * Publishes the rates shown on the confirmation screen, all brand lines in one
 * publish. The key comes from that screen, so a second tap returns the same
 * publish (decision 16.10).
 */
export async function publishToday(_state: ActionResult, form: FormData): Promise<ActionResult> {
  await requireAccount();
  const family = await getFamily();
  if (!family) return failed(text.common.somethingWrong);

  const items = [];
  for (const brandId of form.getAll("brandId").map(String)) {
    const rate = readAmount(form.get(`rate_${brandId}`));
    if (rate === "empty" || rate === "invalid" || Number(rate) <= 0) return failed(text.publish.needRates);
    items.push({ segment_id: family.id, brand_id: brandId, base_rate: Number(rate) });
  }
  if (items.length === 0) return failed(text.publish.needRates);

  const supabase = await createClient();
  const { error } = await supabase.rpc("publish_rates", {
    p_items: items, p_request_key: String(form.get("key")),
  });
  if (error) return failed(plainError(error));
  revalidatePath("/", "layout");
  redirect("/seller/publish?published=1");
}

/** Sends one enquiry. The key comes from the form, so a second tap sends nothing new. */
export async function sendEnquiry(_state: ActionResult, form: FormData): Promise<ActionResult> {
  await requireAccount();
  const family = await getFamily();
  if (!family) return failed(text.common.somethingWrong);

  const quantity = readAmount(form.get("quantity"));
  if (quantity === "invalid") return failed(text.common.enterNumber);
  const pick = (name: string) => String(form.get(name) ?? "") || null;

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("send_enquiry", {
    p_seller_id: pick("sellerId"),
    p_brand_id: pick("brandId"),
    p_segment_id: family.id,
    p_request_key: pick("key"),
    p_product_id: pick("productId"),
    p_size_id: pick("sizeId"),
    p_quantity: quantity === "empty" ? null : quantity,
    p_quantity_unit: quantity === "empty" ? null : "tonne",
    p_note: pick("note"),
    p_show_identity: form.get("showName") === "yes",
  });
  if (error) return failed(plainError(error));
  revalidatePath("/enquiries");
  redirect(`/enquiries?sent=${data}`);
}
