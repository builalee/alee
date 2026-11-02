import { RateCard } from "@/components/rate-card";
import { Card, Screen } from "@/components/ui";
import { getAreaRates, getFamily, getProfile, getRegionName, requireAccount } from "@/lib/api/queries";
import { text } from "@/lib/text";

export default async function SellerProfilePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const me = await requireAccount();
  const [profile, family] = await Promise.all([getProfile(id), getFamily()]);
  if (!profile) {
    return <Screen title={text.buyer.notFound} back="/rates"><p>{text.buyer.notFound}</p></Screen>;
  }
  const [district, rates] = await Promise.all([
    getRegionName(profile.region_id),
    family && me.id !== id ? getAreaRates(family.id, id) : Promise.resolve([]),
  ]);

  return (
    <Screen title={profile.store_name} back="/rates">
      <Card>
        <p>{text.buyer.district}: {district}</p>
        {profile.description && <p>{profile.description}</p>}
        <p className="text-sm">{me.id === id ? text.buyer.yourOwn : text.buyer.contactHidden}</p>
      </Card>
      {rates === null && <p>{text.buyer.failed}</p>}
      {rates?.length === 0 && me.id !== id && <p>{text.buyer.none}</p>}
      {rates?.map((r) => <RateCard key={r.brandId} rates={r} showSeller={false} />)}
    </Screen>
  );
}
