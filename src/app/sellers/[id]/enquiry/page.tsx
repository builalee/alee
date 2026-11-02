import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { Field, inputStyle, Screen } from "@/components/ui";
import { getBrandLines, getFamily, getFamilyItems, getProfile, requireAccount } from "@/lib/api/queries";
import { sendEnquiry } from "@/lib/api/trade";
import { text } from "@/lib/text";

export default async function EnquiryPage({ params, searchParams }: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ brand?: string }>;
}) {
  const [{ id }, { brand }] = await Promise.all([params, searchParams]);
  await requireAccount();
  const [profile, family] = await Promise.all([getProfile(id), getFamily()]);
  if (!profile || !family) redirect("/rates");
  const [lines, items] = await Promise.all([getBrandLines(id, family.id), getFamilyItems(family.id)]);
  const line = lines.find((l) => l.id === brand) ?? lines[0];
  if (!line) redirect(`/sellers/${id}`);

  return (
    <Screen title={text.enquiry.title} back={`/sellers/${id}`}>
      <p>{text.enquiry.to}: {profile.store_name}, {line.name}</p>
      <ActionForm action={sendEnquiry} submit={text.enquiry.send}>
        {/* Made once per form, so a second tap sends nothing new (decision 16.10). */}
        <input type="hidden" name="key" value={randomUUID()} />
        <input type="hidden" name="sellerId" value={id} />
        <input type="hidden" name="brandId" value={line.id} />
        <Field label={text.enquiry.grade} htmlFor="productId">
          <select id="productId" name="productId" defaultValue="" className={inputStyle}>
            <option value="">{text.enquiry.any}</option>
            {items.grades.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
          </select>
        </Field>
        <Field label={text.enquiry.size} htmlFor="sizeId">
          <select id="sizeId" name="sizeId" defaultValue="" className={inputStyle}>
            <option value="">{text.enquiry.any}</option>
            {items.sizes.map((s) => <option key={s.id} value={s.id}>{s.display_name}</option>)}
          </select>
        </Field>
        <Field label={text.enquiry.quantity} htmlFor="quantity">
          <input id="quantity" name="quantity" type="text" inputMode="decimal" className={inputStyle} />
        </Field>
        <Field label={text.enquiry.note} htmlFor="note">
          <textarea id="note" name="note" rows={3} maxLength={1000} className={inputStyle} />
        </Field>
        <label className="flex min-h-11 items-center gap-2">
          <input type="checkbox" name="showName" value="yes" defaultChecked className="size-5" />
          {text.enquiry.showName}
        </label>
        <p className="text-sm">{text.enquiry.hideNote}</p>
      </ActionForm>
    </Screen>
  );
}
