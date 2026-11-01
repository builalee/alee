"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { failed, plainError, succeeded, type ActionResult } from "@/lib/api/errors";
import { getFamily, requireAccount } from "@/lib/api/queries";
import { readAmount } from "@/lib/money";
import { createClient } from "@/lib/supabase/server";
import { text } from "@/lib/text";

async function context() {
  const me = await requireAccount();
  const family = await getFamily();
  if (!family) throw new Error("No product family is switched on");
  return { me, family, supabase: await createClient() };
}

const finish = (): ActionResult => {
  revalidatePath("/seller", "layout");
  return succeeded;
};

export async function saveProfile(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const { me, supabase } = await context();
  const name = String(form.get("storeName") ?? "").trim();
  const regionId = String(form.get("regionId") ?? "");
  const visibility = String(form.get("visibility") ?? "");
  if (!name || !regionId || !visibility) return failed(text.signup.fillAll);

  const { error } = await supabase.from("seller_profiles").upsert({
    account_id: me.id,
    store_name: name,
    region_id: regionId,
    is_public: visibility === "public",
  });
  return error ? failed(plainError(error)) : finish();
}

/** A family must be on his list before a brand can be added to it. */
async function ensureFamily(ctx: Awaited<ReturnType<typeof context>>) {
  const { me, family, supabase } = ctx;
  const { data } = await supabase.from("seller_segments").select("seller_id")
    .eq("seller_id", me.id).eq("segment_id", family.id).maybeSingle();
  if (data) return null;
  const { error } = await supabase.from("seller_segments")
    .insert({ seller_id: me.id, segment_id: family.id, base_unit: family.default_base_unit });
  return error;
}

export async function addBrand(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const ctx = await context();
  const brandId = String(form.get("brandId") ?? "");
  if (!brandId) return failed(text.signup.fillAll);

  const familyError = await ensureFamily(ctx);
  if (familyError) return failed(plainError(familyError));
  const { error } = await ctx.supabase.from("seller_brands")
    .insert({ seller_id: ctx.me.id, brand_id: brandId, segment_id: ctx.family.id });
  return error ? failed(plainError(error)) : finish();
}

export async function requestBrand(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const { family, supabase } = await context();
  const name = String(form.get("name") ?? "").trim();
  if (!name) return failed(text.signup.fillAll);
  const { error } = await supabase.rpc("request_brand", { p_name: name, p_segment_ids: [family.id] });
  return error ? failed(plainError(error)) : finish();
}

export async function claimBrand(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const { supabase } = await context();
  const { error } = await supabase.rpc("claim_brand", { p_brand_id: String(form.get("brandId")) });
  return error ? failed(plainError(error)) : finish();
}

export async function saveProducts(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const { me, family, supabase } = await context();
  const brandId = String(form.get("brandId"));
  const gradesOn = new Set(form.getAll("grade").map(String));
  const sizesOn = new Set(form.getAll("size").map(String));
  if (gradesOn.size === 0 || sizesOn.size === 0) return failed(text.products.pickOne);

  const { data: chart } = await supabase.from("charts").select("id").eq("seller_id", me.id)
    .eq("segment_id", family.id).eq("chart_type", "size").eq("is_active", true).limit(1).maybeSingle();

  // The unit is chosen once, before the template is copied in that unit:
  // converting saved charts when a unit changes isn't built yet (decision 2.8).
  if (!chart) {
    const unit = form.get("unit") === "kg" ? "kg" : "tonne";
    const { error: unitError } = await supabase.from("seller_segments")
      .update({ base_unit: unit }).eq("seller_id", me.id).eq("segment_id", family.id);
    if (unitError) return failed(plainError(unitError));

    const { data: template } = await supabase.from("charts").select("id").eq("is_template", true)
      .eq("segment_id", family.id).eq("chart_type", "size").eq("is_active", true).limit(1).single();
    const { error } = await supabase.rpc("copy_template", {
      p_template_id: template?.id, p_name: text.rates.sizeChartName, p_seller_id: me.id,
    });
    if (error) return failed(plainError(error));
  }

  const [{ data: grades }, { data: sizes }] = await Promise.all([
    supabase.from("products").select("id").eq("segment_id", family.id).eq("is_active", true),
    supabase.from("sizes").select("id").eq("segment_id", family.id).eq("is_active", true),
  ]);
  const { error: gradeError } = await supabase.from("seller_grades").upsert(
    (grades ?? []).map((g) => ({ seller_id: me.id, brand_id: brandId, product_id: g.id, is_selected: gradesOn.has(g.id) })),
    { onConflict: "seller_id,brand_id,product_id" },
  );
  if (gradeError) return failed(plainError(gradeError));
  const { error: sizeError } = await supabase.from("seller_sizes").upsert(
    (sizes ?? []).map((s) => ({ seller_id: me.id, brand_id: brandId, size_id: s.id, is_selected: sizesOn.has(s.id) })),
    { onConflict: "seller_id,brand_id,size_id" },
  );
  if (sizeError) return failed(plainError(sizeError));

  revalidatePath("/seller", "layout");
  redirect(`/seller/rates?brand=${brandId}`);
}

/**
 * Grade premium and loading are one figure each for the demo (decision 16.6),
 * but they are saved on every district he fills in, never on an "everywhere"
 * row: a district he leaves out must stay "not set up", never priced.
 */
export async function saveRates(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const { me, family, supabase } = await context();
  const brandId = String(form.get("brandId"));

  const { data: selected } = await supabase.from("seller_grades").select("product_id")
    .eq("seller_id", me.id).eq("brand_id", brandId).eq("is_selected", true);
  const { data: sizeChart } = await supabase.from("charts").select("id").eq("seller_id", me.id)
    .eq("segment_id", family.id).eq("chart_type", "size").eq("is_active", true).limit(1).maybeSingle();
  if (!selected?.length || !sizeChart) return failed(text.rates.needProducts);

  const grades: { product_id: string; premium: string }[] = [];
  for (const { product_id } of selected) {
    const premium = readAmount(form.get(`premium_${product_id}`));
    if (premium === "empty") return failed(text.rates.needAllPremiums);
    if (premium === "invalid") return failed(text.common.enterNumber);
    grades.push({ product_id, premium });
  }

  const loading = readAmount(form.get("loading"));
  if (loading === "empty") return failed(text.rates.needLoading);
  if (loading === "invalid") return failed(text.common.enterNumber);

  const areas: { region_id: string; area_difference: string }[] = [];
  for (const [key, value] of form.entries()) {
    if (!key.startsWith("area_")) continue;
    const amount = readAmount(value);
    if (amount === "invalid") return failed(text.common.enterNumber);
    if (amount !== "empty") areas.push({ region_id: key.slice("area_".length), area_difference: amount });
  }
  if (areas.length === 0) return failed(text.rates.needOneArea);

  const { data: line } = await supabase.from("seller_segments").select("base_unit")
    .eq("seller_id", me.id).eq("segment_id", family.id).single();

  let { data: loadingChart } = await supabase.from("charts").select("id").eq("seller_id", me.id)
    .eq("segment_id", family.id).eq("chart_type", "loading").eq("is_active", true).limit(1).maybeSingle();
  if (!loadingChart) {
    const { data, error } = await supabase.from("charts")
      .insert({ seller_id: me.id, segment_id: family.id, chart_type: "loading", name: text.rates.loadingChartName })
      .select("id").single();
    if (error) return failed(plainError(error));
    loadingChart = data;
  }
  const { error: figureError } = await supabase.rpc("save_chart_version", {
    p_chart_id: loadingChart.id, p_unit: line?.base_unit, p_figures: [{ size_id: null, amount: loading }],
  });
  if (figureError) return failed(plainError(figureError));

  const { error } = await supabase.rpc("save_area_settings", {
    p_segment_id: family.id,
    p_areas: areas.map((a) => ({ ...a, size_chart_id: sizeChart.id, loading_chart_id: loadingChart.id, grades })),
    p_seller_id: me.id,
    p_brand_id: brandId,
  });
  return error ? failed(plainError(error)) : finish();
}

export async function saveClosingTime(_state: ActionResult, form: FormData): Promise<ActionResult> {
  const { me, supabase } = await context();
  const { error } = await supabase.from("seller_profiles")
    .update({ market_close_time: String(form.get("closeTime")) }).eq("account_id", me.id);
  return error ? failed(plainError(error)) : finish();
}
