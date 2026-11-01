import { ActionForm } from "@/components/action-form";
import { DistrictSelect, Field, inputStyle, Screen } from "@/components/ui";
import { getDistricts, getProfile, requireAccount } from "@/lib/api/queries";
import { saveProfile } from "@/lib/api/seller";
import { text } from "@/lib/text";

export default async function ProfilePage() {
  const me = await requireAccount();
  const [profile, districts] = await Promise.all([getProfile(me.id), getDistricts()]);

  return (
    <Screen title={text.seller.stepProfile} back="/seller">
      <ActionForm action={saveProfile} submit={text.common.save}>
        <Field label={text.profile.businessName} htmlFor="storeName">
          <input id="storeName" name="storeName" required className={inputStyle}
            defaultValue={profile?.store_name ?? me.account?.firm_name ?? ""} />
        </Field>
        <Field label={text.profile.plantCity} htmlFor="regionId">
          <DistrictSelect id="regionId" name="regionId" districts={districts}
            value={profile?.region_id ?? me.account?.region_id} />
        </Field>
        <fieldset className="flex flex-col gap-2">
          <legend className="font-medium">{text.profile.visibility}</legend>
          <label className="flex items-center gap-2">
            <input type="radio" name="visibility" value="public" className="size-5" defaultChecked={profile?.is_public !== false} />
            {text.profile.public}
          </label>
          <label className="flex items-center gap-2">
            <input type="radio" name="visibility" value="private" className="size-5" defaultChecked={profile?.is_public === false} />
            {text.profile.private}
          </label>
          <p className="text-sm">{text.profile.privateNote}</p>
        </fieldset>
      </ActionForm>
    </Screen>
  );
}
