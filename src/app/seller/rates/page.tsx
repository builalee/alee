import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { AreaDifferences, Amount } from "@/components/amount";
import { Card, Field, Screen } from "@/components/ui";
import { getBrandLines, getDistricts, getFamily, getOffering, getRatesSetup, requireAccount } from "@/lib/api/queries";
import { saveRates } from "@/lib/api/seller";
import { text } from "@/lib/text";

export default async function RatesPage({ searchParams }: { searchParams: Promise<{ brand?: string }> }) {
  const { brand } = await searchParams;
  const me = await requireAccount();
  const family = await getFamily();
  if (!family) redirect("/seller");
  const line = (await getBrandLines(me.id, family.id)).find((l) => l.id === brand);
  if (!line) redirect("/seller");

  const offering = await getOffering(me.id, line.id, family.id);
  if (!offering.isSetUp) redirect(`/seller/products?brand=${line.id}`);
  const [setup, districts] = await Promise.all([getRatesSetup(me.id, line.id, family.id), getDistricts()]);
  const unit = text.products[offering.unit];
  const placeholder = `${text.rates.amountPer} ${unit}`;

  return (
    <Screen title={`${line.name}: ${text.seller.stepRates}`} back="/seller">
      <p>{text.rates.intro}</p>
      <p className="text-sm">{text.rates.perUnit} {unit}. {text.rates.signNote}</p>
      <ActionForm action={saveRates} submit={text.common.save} startSaved={setup.hasSetup}>
        <input type="hidden" name="brandId" value={line.id} />
        <Card>
          <h2 className="font-semibold">{text.rates.premiums}</h2>
          <p className="text-sm">{text.rates.premiumsNote}</p>
          {offering.grades.filter((g) => g.selected).map((g) => (
            <Field key={g.id} label={g.name} htmlFor={`premium_${g.id}`}>
              <Amount name={`premium_${g.id}`} placeholder={placeholder} zeroLabel={text.rates.baseGrade}
                saved={setup.premiums[g.id]} signed />
            </Field>
          ))}
        </Card>
        <Card>
          <Field label={text.rates.loading} htmlFor="loading">
            <p className="text-sm">{text.rates.loadingNote}</p>
            <Amount name="loading" placeholder={placeholder} zeroLabel={text.rates.noLoading} saved={setup.loading} />
          </Field>
        </Card>
        <Card>
          <h2 className="font-semibold">{text.rates.areas}</h2>
          <p className="text-sm">{text.rates.areasNote}</p>
          <AreaDifferences districts={districts} saved={setup.differences} placeholder={placeholder} />
        </Card>
      </ActionForm>
    </Screen>
  );
}
