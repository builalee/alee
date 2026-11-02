import { RateCard } from "@/components/rate-card";
import { Screen } from "@/components/ui";
import { getAreaRates, getFamily, getRegionName, requireAccount } from "@/lib/api/queries";
import { text } from "@/lib/text";

export default async function AreaRatesPage() {
  const me = await requireAccount();
  const family = await getFamily();
  const [area, rates] = await Promise.all([
    getRegionName(me.account!.region_id),
    family ? getAreaRates(family.id) : Promise.resolve(null),
  ]);

  return (
    <Screen title={`${text.buyer.title} ${area}`} back="/">
      {rates === null && <p>{text.buyer.failed}</p>}
      {rates?.length === 0 && <p>{text.buyer.none}</p>}
      {rates?.map((r) => <RateCard key={`${r.sellerId}-${r.brandId}`} rates={r} showSeller />)}
    </Screen>
  );
}
