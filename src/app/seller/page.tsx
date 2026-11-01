import Link from "next/link";
import { Card, Screen } from "@/components/ui";
import { getBrandLines, getFamily, getMissing, getOffering, getProfile, requireAccount } from "@/lib/api/queries";
import { text } from "@/lib/text";

function Step({ href, label, done }: { href: string; label: string; done: boolean }) {
  return (
    <Link href={href} className="flex items-center justify-between gap-3 border-t border-current/15 pt-3">
      <span className="font-medium underline">{label}</span>
      <span className="shrink-0 text-sm">{done ? text.seller.done : text.seller.todo}</span>
    </Link>
  );
}

export default async function SellerPage() {
  const me = await requireAccount();
  const [profile, family] = await Promise.all([getProfile(me.id), getFamily()]);

  if (!profile || !family) {
    return (
      <Screen title={text.seller.title} back="/">
        <Card>
          <p>{text.seller.firstProfile}</p>
          <Step href="/seller/profile" label={text.seller.stepProfile} done={false} />
        </Card>
      </Screen>
    );
  }

  const lines = await getBrandLines(me.id, family.id);
  const checks = await Promise.all(lines.map(async (line) => {
    const [offering, missing] = await Promise.all([
      getOffering(me.id, line.id, family.id),
      getMissing(me.id, line.id, family.id),
    ]);
    return { line, offering, missing };
  }));

  return (
    <Screen title={text.seller.title} back="/">
      <Card>
        <Step href="/seller/profile" label={text.seller.stepProfile} done />
        <Step href="/seller/brand" label={text.seller.stepBrand} done={lines.length > 0} />
        <Step href="/seller/closing" label={text.seller.stepClosing} done={Boolean(profile.market_close_time)} />
        <Link href="/seller/distributors" className="border-t border-current/15 pt-3 font-medium underline">
          {text.seller.stepDistributors}
        </Link>
      </Card>
      {checks.map(({ line, offering, missing }) => (
        <Card key={line.id}>
          <h2 className="font-semibold">{line.name}</h2>
          <Step href={`/seller/products?brand=${line.id}`} label={text.seller.stepProducts} done={offering.isSetUp} />
          <Step href={`/seller/rates?brand=${line.id}`} label={text.seller.stepRates} done={missing !== null && missing.length === 0} />
          {missing === null && <p className="text-sm">{text.seller.previewFailed}</p>}
          {missing?.length === 0 && <p className="text-green-700 dark:text-green-400">{text.seller.ready}</p>}
          {missing && missing.length > 0 && (
            <div className="text-red-700 dark:text-red-400">
              <p className="font-medium">{text.seller.needsFix}</p>
              <ul className="list-disc pl-5">{missing.map((m) => <li key={m}>{m}</li>)}</ul>
            </div>
          )}
        </Card>
      ))}
    </Screen>
  );
}
