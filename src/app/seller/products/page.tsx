import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { Field, inputStyle, Screen } from "@/components/ui";
import { getBrandLines, getFamily, getOffering, requireAccount } from "@/lib/api/queries";
import { saveProducts } from "@/lib/api/seller";
import { text } from "@/lib/text";

export default async function ProductsPage({ searchParams }: { searchParams: Promise<{ brand?: string }> }) {
  const { brand } = await searchParams;
  const me = await requireAccount();
  const family = await getFamily();
  if (!family) redirect("/seller");
  const line = (await getBrandLines(me.id, family.id)).find((l) => l.id === brand);
  if (!line) redirect("/seller");

  const offering = await getOffering(me.id, line.id, family.id);
  // A new brand line starts with everything ticked; he unticks what he doesn't sell.
  const ticked = (selected: boolean) => selected || !offering.isSetUp;

  return (
    <Screen title={`${line.name}: ${text.seller.stepProducts}`} back="/seller">
      <p>{text.products.intro}</p>
      <ActionForm action={saveProducts} submit={text.common.save} startSaved={offering.isSetUp}>
        <input type="hidden" name="brandId" value={line.id} />
        {offering.hasSizeChart ? (
          <p>{text.products.unitFixed} {text.products[offering.unit]}</p>
        ) : (
          <Field label={text.products.unit} htmlFor="unit">
            <select id="unit" name="unit" defaultValue={offering.unit} className={inputStyle}>
              <option value="tonne">{text.products.tonne}</option>
              <option value="kg">{text.products.kg}</option>
            </select>
            <p className="text-sm">{text.products.unitNote}</p>
          </Field>
        )}
        <fieldset className="grid grid-cols-2 gap-2">
          <legend className="mb-2 font-medium">{text.products.grades}</legend>
          {offering.grades.map((g) => (
            <label key={g.id} className="flex items-center gap-2">
              <input type="checkbox" name="grade" value={g.id} defaultChecked={ticked(g.selected)} className="size-5" />
              {g.name}
            </label>
          ))}
        </fieldset>
        <fieldset className="grid grid-cols-3 gap-2">
          <legend className="mb-2 font-medium">{text.products.sizes}</legend>
          {offering.sizes.map((s) => (
            <label key={s.id} className="flex items-center gap-2">
              <input type="checkbox" name="size" value={s.id} defaultChecked={ticked(s.selected)} className="size-5" />
              {s.display_name}
            </label>
          ))}
        </fieldset>
        <p className="text-sm">{text.products.sizeNote}</p>
      </ActionForm>
    </Screen>
  );
}
