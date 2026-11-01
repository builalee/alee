import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { Card, DistrictSelect, Field, inputStyle, Screen } from "@/components/ui";
import { getDistricts, getProfile, getTerritory, requireAccount } from "@/lib/api/queries";
import { offerTerritory, respondToTerritory } from "@/lib/api/territory";
import { text } from "@/lib/text";

const typeLabel = (type: string) =>
  type === "distributor_prices" ? text.territory.typeA : text.territory.typeB;

function Move({ id, move, label }: { id: string; move: string; label: string }) {
  return (
    <ActionForm action={respondToTerritory} secondary submit={label}>
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="move" value={move} />
    </ActionForm>
  );
}

export default async function DistributorsPage() {
  const me = await requireAccount();
  const profile = await getProfile(me.id);
  if (!profile) redirect("/seller");
  const [territory, districts] = await Promise.all([getTerritory(me.id), getDistricts()]);

  return (
    <Screen title={text.seller.stepDistributors} back="/seller">
      <Card>
        <h2 className="font-semibold">{text.territory.toYou}</h2>
        {territory.toMe.length === 0 && <p>{text.common.none}</p>}
        {territory.toMe.map((a) => (
          <div key={a.id} className="flex flex-col gap-2 border-t border-current/15 pt-3">
            <p>{a.manufacturer}: {a.area}</p>
            <p className="text-sm">{typeLabel(a.type)} · {text.territory.status[a.status]}</p>
            {a.status === "offered" ? (
              <div className="grid grid-cols-2 gap-2">
                <Move id={a.id} move="accept" label={text.territory.accept} />
                <Move id={a.id} move="decline" label={text.territory.decline} />
              </div>
            ) : (
              <Move id={a.id} move="end" label={text.territory.end} />
            )}
          </div>
        ))}
      </Card>

      {territory.ownedBrands.length === 0 ? (
        <p>{text.territory.needOwned}</p>
      ) : (
        <>
          <Card>
            <ActionForm action={offerTerritory} submit={text.territory.offer}>
              <h2 className="font-semibold">{text.territory.appoint}</h2>
              <Field label={text.territory.brand} htmlFor="brandId">
                <select id="brandId" name="brandId" required className={inputStyle}>
                  {territory.ownedBrands.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
                </select>
              </Field>
              <Field label={text.territory.area} htmlFor="regionId">
                <DistrictSelect id="regionId" name="regionId" districts={districts} />
              </Field>
              <Field label={text.territory.distributor} htmlFor="distributorId">
                <select id="distributorId" name="distributorId" required defaultValue="" className={inputStyle}>
                  <option value="" disabled>{text.common.choose}</option>
                  {territory.distributors.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
                </select>
              </Field>
              <fieldset className="flex flex-col gap-2">
                <legend className="font-medium">{text.territory.type}</legend>
                <label className="flex items-center gap-2">
                  <input type="radio" name="type" value="distributor_prices" required className="size-5" />
                  {text.territory.typeA}
                </label>
                <label className="flex items-center gap-2">
                  <input type="radio" name="type" value="manufacturer_prices" className="size-5" />
                  {text.territory.typeB}
                </label>
              </fieldset>
            </ActionForm>
          </Card>
          <Card>
            <h2 className="font-semibold">{text.territory.yours}</h2>
            {territory.mine.length === 0 && <p>{text.common.none}</p>}
            {territory.mine.map((a) => (
              <div key={a.id} className="flex flex-col gap-2 border-t border-current/15 pt-3">
                <p>{a.distributor}: {a.area}</p>
                <p className="text-sm">{typeLabel(a.type)} · {text.territory.status[a.status]}</p>
                <Move id={a.id} move="end" label={a.status === "active" ? text.territory.end : text.territory.withdraw} />
              </div>
            ))}
          </Card>
        </>
      )}
    </Screen>
  );
}
