import { redirect } from "next/navigation";
import { cache } from "react";
import { createClient } from "@/lib/supabase/server";

/**
 * Everything screens read. Each read runs as the logged-in person, so Row
 * Level Security decides what comes back. Only server pages import this file.
 */

type Role = "retailer" | "wholesaler" | "distributor" | "manufacturer";

/** Who is logged in, the role he actually has, and any role still waiting. */
export const getMe = cache(async () => {
  const supabase = await createClient();
  const { data } = await supabase.auth.getUser();
  const user = data.user;
  if (!user) return null;

  const [{ data: account }, { data: requests }, { data: removals }] = await Promise.all([
    supabase.from("accounts").select("*").eq("id", user.id).maybeSingle(),
    supabase.from("role_requests").select("id, requested_role, status, requested_at")
      .eq("account_id", user.id).order("requested_at", { ascending: false }),
    supabase.from("role_removals").select("request_id"),
  ]);

  const removed = new Set((removals ?? []).map((r) => r.request_id));
  const role: Role = requests?.find((r) => r.status === "approved" && !removed.has(r.id))?.requested_role ?? "retailer";
  const pendingRole: Role | null = requests?.find((r) => r.status === "requested")?.requested_role ?? null;

  return {
    id: user.id,
    phone: user.phone ?? "",
    isAdmin: user.app_metadata?.role === "admin",
    account,
    role,
    pendingRole,
  };
});

export async function requireAccount() {
  const me = await getMe();
  if (!me) redirect("/login");
  if (!me.account) redirect("/signup");
  return me;
}

/** Manufacturers, including one still waiting for ALEE, see the owner's screens. */
export const isManufacturer = (me: { role: Role; pendingRole: Role | null }) =>
  me.role === "manufacturer" || me.pendingRole === "manufacturer";

export async function requireAdmin() {
  const me = await getMe();
  if (!me) redirect("/login");
  if (!me.isAdmin) redirect("/");
  return me;
}

/**
 * Public lists that rarely change are remembered for ten minutes, so a page
 * doesn't wait for them on every visit. Rates and personal data never are.
 */
const REMEMBER_MS = 10 * 60 * 1000;

function remembered<T>(load: () => Promise<T | null>) {
  let saved: { value: T; at: number } | null = null;
  return async () => {
    if (saved && Date.now() - saved.at < REMEMBER_MS) return saved.value;
    const value = await load();
    if (value) saved = { value, at: Date.now() };
    return value;
  };
}

/** Maharashtra's districts, in name order (decision 16.1). Always by id afterwards. */
const loadDistricts = remembered(async () => {
  const supabase = await createClient();
  const { data: state } = await supabase
    .from("regions").select("id, name").eq("level", "state").eq("name", "Maharashtra").single();
  const { data } = await supabase.from("regions").select("id, name").eq("level", "district")
    .eq("parent_id", state?.id).eq("is_active", true).eq("is_approved", true).order("name");
  if (!data?.length) return null;
  return data.map((d) => ({ id: d.id as string, name: d.name as string, stateName: state?.name as string }));
});

export const getDistricts = cache(async () => (await loadDistricts()) ?? []);

/** The product family the demo sells: the first one with sizes switched on. */
export const getFamily = cache(remembered(async () => {
  const supabase = await createClient();
  const [{ data: segments }, { data: sizes }] = await Promise.all([
    supabase.from("segments").select("id, name, default_base_unit").eq("is_active", true).order("sort_order"),
    supabase.from("sizes").select("segment_id").eq("is_active", true),
  ]);
  const live = new Set((sizes ?? []).map((s) => s.segment_id));
  return segments?.find((s) => live.has(s.id)) ?? null;
}));

export async function getAdminQueue() {
  const supabase = await createClient();
  const [roles, brands, claims] = await Promise.all([
    supabase.from("role_requests").select("id, account_id, requested_role, requested_at")
      .eq("status", "requested").order("requested_at"),
    supabase.from("brands").select("id, name, requested_by").eq("status", "requested").order("created_at"),
    supabase.from("brand_claims").select("id, brand_id, manufacturer_id").eq("status", "claimed"),
  ]);

  const ids = [...new Set((roles.data ?? []).map((r) => r.account_id))];
  const brandIds = (claims.data ?? []).map((c) => c.brand_id);
  const makerIds = (claims.data ?? []).map((c) => c.manufacturer_id);
  const [{ data: accounts }, { data: claimed }, { data: makers }] = await Promise.all([
    supabase.from("accounts").select("id, full_name, firm_name").in("id", ids),
    supabase.from("brands").select("id, name").in("id", brandIds),
    supabase.from("seller_profiles").select("account_id, store_name").in("account_id", makerIds),
  ]);

  return {
    roles: (roles.data ?? []).map((r) => {
      const a = accounts?.find((x) => x.id === r.account_id);
      return { id: r.id, role: r.requested_role as Role, who: a?.firm_name || a?.full_name || "" };
    }),
    brands: brands.data ?? [],
    claims: (claims.data ?? []).map((c) => ({
      id: c.id,
      brand: claimed?.find((b) => b.id === c.brand_id)?.name ?? "",
      who: makers?.find((m) => m.account_id === c.manufacturer_id)?.store_name ?? "",
    })),
  };
}

export async function getProfile(sellerId: string) {
  const supabase = await createClient();
  const { data } = await supabase.from("seller_profiles").select("*").eq("account_id", sellerId).maybeSingle();
  return data;
}

/** A seller's brand lines in the family, with ownership and claim status. */
export async function getBrandLines(sellerId: string, familyId: string) {
  const supabase = await createClient();
  const { data: lines } = await supabase.from("seller_brands").select("brand_id")
    .eq("seller_id", sellerId).eq("segment_id", familyId).eq("is_active", true);
  const brandIds = (lines ?? []).map((l) => l.brand_id);
  const [{ data: brands }, { data: claims }, names] = await Promise.all([
    supabase.from("brands").select("id, name, is_regular, owner_id").in("id", brandIds),
    supabase.from("brand_claims").select("brand_id, status").eq("manufacturer_id", sellerId).eq("status", "claimed"),
    Promise.all(brandIds.map((id) => supabase.rpc("brand_display_name", { p_brand_id: id, p_segment_id: familyId }))),
  ]);
  return brandIds.map((id, i) => {
    const b = brands?.find((x) => x.id === id);
    return {
      id: id as string,
      name: (names[i].data as string) ?? b?.name ?? "",
      isRegular: Boolean(b?.is_regular),
      isOwner: b?.owner_id === sellerId,
      hasOwner: Boolean(b?.owner_id),
      isClaimed: Boolean(claims?.some((c) => c.brand_id === id)),
    };
  });
}

/** Approved brands covering the family, plus what this seller has requested. */
export async function getBrandChoices(sellerId: string, familyId: string) {
  const supabase = await createClient();
  const [{ data: brands }, { data: families }, { data: mine }] = await Promise.all([
    supabase.from("brands").select("id, name, is_regular").eq("status", "approved").eq("is_active", true).order("name"),
    supabase.from("brand_families").select("brand_id").eq("segment_id", familyId),
    supabase.from("brands").select("id, name").eq("requested_by", sellerId).eq("status", "requested"),
  ]);
  const covered = new Set((families ?? []).map((f) => f.brand_id));
  return {
    choices: (brands ?? []).filter((b) => b.is_regular || covered.has(b.id)),
    waiting: mine ?? [],
  };
}

export async function getOffering(sellerId: string, brandId: string, familyId: string) {
  const supabase = await createClient();
  const [{ data: grades }, { data: sizes }, { data: myGrades }, { data: mySizes }, { data: line }, { data: chart }] =
    await Promise.all([
      supabase.from("products").select("id, name").eq("segment_id", familyId).eq("is_active", true).order("name"),
      supabase.from("sizes").select("id, display_name").eq("segment_id", familyId).eq("is_active", true).order("sort_order"),
      supabase.from("seller_grades").select("product_id").eq("seller_id", sellerId).eq("brand_id", brandId).eq("is_selected", true),
      supabase.from("seller_sizes").select("size_id").eq("seller_id", sellerId).eq("brand_id", brandId).eq("is_selected", true),
      supabase.from("seller_segments").select("base_unit").eq("seller_id", sellerId).eq("segment_id", familyId).maybeSingle(),
      supabase.from("charts").select("id").eq("seller_id", sellerId).eq("segment_id", familyId)
        .eq("chart_type", "size").eq("is_active", true).limit(1).maybeSingle(),
    ]);
  const selectedGrades = new Set((myGrades ?? []).map((g) => g.product_id));
  const selectedSizes = new Set((mySizes ?? []).map((s) => s.size_id));
  return {
    grades: (grades ?? []).map((g) => ({ ...g, selected: selectedGrades.has(g.id) })),
    sizes: (sizes ?? []).map((s) => ({ ...s, selected: selectedSizes.has(s.id) })),
    unit: (line?.base_unit ?? "tonne") as "tonne" | "kg",
    hasSizeChart: Boolean(chart),
    isSetUp: selectedGrades.size > 0 && selectedSizes.size > 0,
  };
}

/** The saved figures for the rates screen. Empty stays empty, never 0. */
export async function getRatesSetup(sellerId: string, brandId: string, familyId: string) {
  const supabase = await createClient();
  const { data: version } = await supabase.from("area_setting_versions").select("id")
    .eq("seller_id", sellerId).eq("brand_id", brandId).eq("segment_id", familyId)
    .order("version_number", { ascending: false }).limit(1).maybeSingle();

  const differences: Record<string, string> = {};
  const premiums: Record<string, string> = {};
  let loading: string | null = null;

  if (version) {
    const { data: areas } = await supabase.from("area_settings")
      .select("id, region_id, area_difference, loading_chart_id").eq("version_id", version.id);
    for (const a of areas ?? []) {
      if (a.region_id && a.area_difference !== null) differences[a.region_id] = String(a.area_difference);
    }
    const { data: grades } = await supabase.from("area_grade_settings")
      .select("product_id, grade_premium").in("area_setting_id", (areas ?? []).map((a) => a.id));
    for (const g of grades ?? []) {
      if (g.grade_premium !== null) premiums[g.product_id] = String(g.grade_premium);
    }
    const chartId = areas?.find((a) => a.loading_chart_id)?.loading_chart_id;
    if (chartId) {
      const { data: latest } = await supabase.from("chart_versions").select("id")
        .eq("chart_id", chartId).order("version_number", { ascending: false }).limit(1).maybeSingle();
      const { data: figure } = await supabase.from("chart_version_figures").select("amount")
        .eq("version_id", latest?.id).is("size_id", null).maybeSingle();
      if (figure) loading = String(figure.amount);
    }
  }
  return { hasSetup: Boolean(version), differences, premiums, loading };
}

/**
 * What the rate engine says is missing for this brand line. The placeholder
 * rate is never shown: only the engine's own "what to fix" list is used.
 */
export async function getMissing(sellerId: string, brandId: string, familyId: string): Promise<string[] | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rate_preview", {
    p_brand_id: brandId, p_segment_id: familyId, p_base_rate: 1, p_seller_id: sellerId,
  });
  if (error) return null;
  const lines = (data ?? []) as { missing: string[] | null }[];
  return [...new Set(lines.flatMap((l) => l.missing ?? []))];
}

/** One line of what a buyer sees, from the rate engine. Final figures only. */
export type BuyerLine = {
  brand_name: string;
  product_id: string | null;
  grade: string | null;
  size_id: string | null;
  size: string | null;
  status: string;
  message: string | null;
  tag: string | null;
  area_rate_text: string | null;
  area_rate_label: string | null;
  area_discount_text: string | null;
  ex_works_label: string | null;
  ex_works_text: string | null;
  ex_works_discount_text: string | null;
  market: string | null;
  closed_at: string | null;
  published_at: string | null;
  published_today: boolean | null;
};

export type SellerRates = { sellerId: string; storeName: string; brandId: string; lines: BuyerLine[] };

/** Every public seller's rates for the logged-in buyer's own area, one group per brand line. */
export async function getAreaRates(familyId: string, sellerId?: string): Promise<SellerRates[] | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("area_rates", { p_segment_id: familyId, p_seller_id: sellerId ?? null });
  if (error) return null;
  const groups: SellerRates[] = [];
  for (const row of (data ?? []) as { seller_id: string; store_name: string; brand_id: string; line: BuyerLine }[]) {
    let group = groups.find((g) => g.sellerId === row.seller_id && g.brandId === row.brand_id);
    if (!group) {
      group = { sellerId: row.seller_id, storeName: row.store_name, brandId: row.brand_id, lines: [] };
      groups.push(group);
    }
    group.lines.push(row.line);
  }
  return groups;
}

export const getRegionName = async (regionId: string) => {
  const supabase = await createClient();
  const { data } = await supabase.from("regions").select("name").eq("id", regionId).maybeSingle();
  return (data?.name as string | undefined) ?? "";
};

/** The seller's brand lines as they stand for today's publish. */
export async function getPublishLines(familyId: string) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("publish_prefill");
  return ((data ?? []) as {
    brand_id: string; segment_id: string; line_name: string; last_base_rate: string | null;
    current_unit: "tonne" | "kg"; last_published_at: string | null;
    move_status: "move" | "needs_rate" | "unit_changed" | "not_quoting";
  }[]).filter((l) => l.segment_id === familyId);
}

/** What buyers in every area would see at this basic rate, from the rate engine. */
export async function getPublishPreview(brandId: string, familyId: string, baseRate: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rate_preview", {
    p_brand_id: brandId, p_segment_id: familyId, p_base_rate: baseRate,
  });
  if (error) return { error: error.code === "P0001" ? error.message : null, lines: [] };
  return {
    error: null,
    lines: (data ?? []) as {
      area_name: string | null; grade: string | null; size: string | null; status: string; message: string | null;
      area_rate_text: string | null; area_discount_text: string | null; missing: string[] | null;
    }[],
  };
}

/** Enquiries this person sent. */
export async function getMyEnquiries() {
  const supabase = await createClient();
  const { data } = await supabase.from("enquiries")
    .select("id, created_at, seller_id, recipient_id, brand_id, quantity, quantity_unit, note, received_after_close")
    .order("created_at", { ascending: false });
  const rows = data ?? [];
  const sellerIds = [...new Set(rows.flatMap((e) => [e.seller_id, e.recipient_id]))];
  const [{ data: sellers }, { data: brands }] = await Promise.all([
    supabase.from("seller_profiles").select("account_id, store_name").in("account_id", sellerIds),
    supabase.from("brands").select("id, name").in("id", [...new Set(rows.map((e) => e.brand_id))]),
  ]);
  const store = (id: string) => sellers?.find((s) => s.account_id === id)?.store_name ?? "";
  return rows.map((e) => ({
    id: e.id as string,
    createdAt: e.created_at as string,
    seller: store(e.seller_id),
    recipient: e.recipient_id !== e.seller_id ? store(e.recipient_id) : null,
    brand: brands?.find((b) => b.id === e.brand_id)?.name ?? "",
    quantity: e.quantity === null ? null : `${e.quantity} ${e.quantity_unit}`,
    note: e.note as string | null,
    afterClose: Boolean(e.received_after_close),
  }));
}

/** Enquiries this seller received. A hidden name comes back empty from the database. */
export async function getReceivedEnquiries() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("received_enquiries");
  return (data ?? []) as {
    id: string; created_at: string; brand_name: string; grade: string | null; size: string | null;
    quantity: string | null; quantity_unit: string | null; note: string | null; area_name: string;
    received_after_close: boolean; via_seller: string | null; buyer_name: string | null;
    buyer_phone: string | null; buyer_type: Role; buyer_recent: number;
  }[];
}

/** Grades and sizes a buyer can name in an enquiry. */
export async function getFamilyItems(familyId: string) {
  const supabase = await createClient();
  const [{ data: grades }, { data: sizes }] = await Promise.all([
    supabase.from("products").select("id, name").eq("segment_id", familyId).eq("is_active", true).order("name"),
    supabase.from("sizes").select("id, display_name").eq("segment_id", familyId).eq("is_active", true).order("sort_order"),
  ]);
  return { grades: grades ?? [], sizes: sizes ?? [] };
}

export async function getTerritory(sellerId: string) {
  const supabase = await createClient();
  const [{ data: mine }, { data: toMe }, { data: sellers }, { data: regions }, { data: brands }, { data: approved }] = await Promise.all([
    supabase.from("territory_allocations").select("*").eq("manufacturer_id", sellerId).in("status", ["offered", "active"]),
    supabase.from("territory_allocations").select("*").eq("distributor_id", sellerId).in("status", ["offered", "active"]),
    supabase.from("seller_profiles").select("account_id, store_name"),
    supabase.from("regions").select("id, name").eq("level", "district"),
    supabase.from("brands").select("id, name").eq("owner_id", sellerId),
    supabase.rpc("appointable_distributors"),
  ]);
  const regionName = (id: string) => regions?.find((r) => r.id === id)?.name ?? "";
  const sellerName = (id: string) => sellers?.find((s) => s.account_id === id)?.store_name ?? "";
  const describe = (a: { id: string; region_id: string; allocation_type: string; status: string; manufacturer_id: string; distributor_id: string }) => ({
    id: a.id,
    area: regionName(a.region_id),
    type: a.allocation_type,
    status: a.status as "offered" | "active",
    manufacturer: sellerName(a.manufacturer_id),
    distributor: sellerName(a.distributor_id),
  });
  return {
    mine: (mine ?? []).map(describe),
    toMe: (toMe ?? []).map(describe),
    ownedBrands: brands ?? [],
    distributors: ((approved ?? []) as { account_id: string; store_name: string; region_id: string }[])
      .map((s) => ({ id: s.account_id, name: `${s.store_name} (${regionName(s.region_id)})` })),
  };
}

export type ClientType = "distributor" | "dealer" | "builder" | "retailer";
export type Client = {
  id: string; name: string; phone: string | null; region_id: string | null; client_type: ClientType | null; note: string | null;
};

/** His client book, by name; a search matches name or mobile number. */
export async function getClients(search?: string): Promise<Client[]> {
  const supabase = await createClient();
  const columns = "id, name, phone, region_id, client_type, note";
  const words = (search ?? "").trim();
  if (!words) {
    const { data } = await supabase.from("clients").select(columns).order("name");
    return (data ?? []) as Client[];
  }
  const digits = words.replace(/\D/g, "");
  const [{ data: byName }, { data: byPhone }] = await Promise.all([
    supabase.from("clients").select(columns).ilike("name", `%${words.replace(/[\\%_]/g, (c) => `\\${c}`)}%`).order("name"),
    digits.length >= 3
      ? supabase.from("clients").select(columns).ilike("phone", `%${digits}%`).order("name")
      : Promise.resolve({ data: [] }),
  ]);
  const found = new Map<string, Client>();
  for (const c of [...(byName ?? []), ...(byPhone ?? [])] as Client[]) found.set(c.id, c);
  return [...found.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/** One customer, with his waiting follow-ups and his activity, newest first. */
export async function getClientBook(clientId: string) {
  const supabase = await createClient();
  const [{ data: client }, { data: followUps }, { data: activity }] = await Promise.all([
    supabase.from("clients").select("id, name, phone, region_id, client_type, note").eq("id", clientId).maybeSingle(),
    supabase.from("follow_ups").select("id, due_on, note").eq("client_id", clientId).eq("status", "pending").order("due_on"),
    supabase.from("client_activities").select("id, kind, note, created_at").eq("client_id", clientId)
      .order("created_at", { ascending: false }).limit(50),
  ]);
  if (!client) return null;
  return {
    client: client as Client,
    followUps: (followUps ?? []) as { id: string; due_on: string; note: string | null }[],
    activity: (activity ?? []) as { id: string; kind: "call" | "whatsapp" | "visit"; note: string | null; created_at: string }[],
  };
}

/** The "Today" list: follow-ups due today or overdue, worked out in the database. */
export async function getFollowUpsDue() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("follow_ups_due");
  return (data ?? []) as {
    id: string; client_id: string; client_name: string; phone: string | null; due_on: string; note: string | null; overdue: boolean;
  }[];
}
