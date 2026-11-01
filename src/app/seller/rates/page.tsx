import { redirect } from "next/navigation";
import { ActionForm, ZeroButton } from "@/components/action-form";
import { Card, Field, inputStyle, Screen } from "@/components/ui";
import { getBrandLines, getDistricts, getFamily, getOffering, getRatesSetup, requireAccount } from "@/lib/api/queries";
import { saveRates } from "@/lib/api/seller";
import { text } from "@/lib/text";

const amountProps = { type: "text", inputMode: "decimal", className: inputStyle } as const;

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

  return (
    <Screen title={`${line.name}: ${text.seller.stepRates}`} back="/seller">
      <p>{text.rates.perUnit} {text.products[offering.unit]}. {text.rates.basicRateNote}</p>
      <ActionForm action={saveRates} submit={text.common.save}>
        <input type="hidden" name="brandId" value={line.id} />
        <Card>
          <h2 className="font-semibold">{text.rates.premiums}</h2>
          {offering.grades.filter((g) => g.selected).map((g) => (
            <Field key={g.id} label={g.name} htmlFor={`premium_${g.id}`}>
              <input id={`premium_${g.id}`} name={`premium_${g.id}`} {...amountProps} defaultValue={setup.premiums[g.id] ?? ""} />
              <ZeroButton inputId={`premium_${g.id}`} label={text.rates.baseGrade} />
            </Field>
          ))}
        </Card>
        <Card>
          <Field label={text.rates.loading} htmlFor="loading">
            <input id="loading" name="loading" {...amountProps} defaultValue={setup.loading ?? ""} />
            <ZeroButton inputId="loading" label={text.rates.noLoading} />
          </Field>
        </Card>
        <Card>
          <h2 className="font-semibold">{text.rates.areas}</h2>
          <p className="text-sm">{text.rates.areasNote}</p>
          {districts.map((d) => (
            <Field key={d.id} label={`${d.name} (district, ${d.stateName})`} htmlFor={`area_${d.id}`}>
              <input id={`area_${d.id}`} name={`area_${d.id}`} {...amountProps} defaultValue={setup.differences[d.id] ?? ""} />
              <ZeroButton inputId={`area_${d.id}`} label={text.rates.sameRate} />
            </Field>
          ))}
        </Card>
      </ActionForm>
    </Screen>
  );
}
