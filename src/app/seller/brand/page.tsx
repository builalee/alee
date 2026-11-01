import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { Card, Field, inputStyle, Screen } from "@/components/ui";
import { getBrandChoices, getBrandLines, getFamily, getProfile, isManufacturer, requireAccount } from "@/lib/api/queries";
import { addBrand, claimBrand, requestBrand } from "@/lib/api/seller";
import { text } from "@/lib/text";

export default async function BrandPage() {
  const me = await requireAccount();
  const [profile, family] = await Promise.all([getProfile(me.id), getFamily()]);
  if (!profile || !family) redirect("/seller");

  const [lines, { choices, waiting }] = await Promise.all([
    getBrandLines(me.id, family.id),
    getBrandChoices(me.id, family.id),
  ]);
  const available = choices.filter((c) => !lines.some((l) => l.id === c.id));

  return (
    <Screen title={text.seller.stepBrand} back="/seller">
      {lines.length > 0 && (
        <Card>
          <h2 className="font-semibold">{text.brand.yours}</h2>
          {lines.map((line) => (
            <div key={line.id} className="flex flex-col gap-2 border-t border-current/15 pt-3">
              <p className="font-medium">{line.name}</p>
              <Link href={`/seller/products?brand=${line.id}`} className="underline">{text.brand.setUp}</Link>
              {line.isOwner && <p className="text-sm">{text.brand.owner}</p>}
              {line.isClaimed && <p className="text-sm">{text.brand.claimed}</p>}
              {isManufacturer(me) && !line.isRegular && !line.hasOwner && !line.isClaimed && (
                <ActionForm action={claimBrand} secondary submit={text.brand.claim}>
                  <input type="hidden" name="brandId" value={line.id} />
                </ActionForm>
              )}
            </div>
          ))}
        </Card>
      )}
      <Card>
        <ActionForm action={addBrand} submit={text.brand.addButton}>
          <Field label={text.brand.add} htmlFor="brandId">
            <select id="brandId" name="brandId" required defaultValue="" className={inputStyle}>
              <option value="" disabled>{text.common.choose}</option>
              {available.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
          </Field>
        </ActionForm>
      </Card>
      <Card>
        <ActionForm action={requestBrand} submit={text.brand.requestButton}>
          <Field label={text.brand.request} htmlFor="name">
            <input id="name" name="name" required className={inputStyle} placeholder={text.brand.requestName} />
          </Field>
        </ActionForm>
        {waiting.map((b) => <p key={b.id} className="text-sm">{b.name}: {text.brand.waiting}</p>)}
      </Card>
    </Screen>
  );
}
