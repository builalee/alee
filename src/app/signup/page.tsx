import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { DistrictSelect, Field, inputStyle, Screen } from "@/components/ui";
import { createAccount } from "@/lib/api/account";
import { getDistricts, getMe } from "@/lib/api/queries";
import { text } from "@/lib/text";

const ROLES = ["retailer", "wholesaler", "distributor", "manufacturer"] as const;

export default async function SignupPage() {
  const me = await getMe();
  if (!me) redirect("/login");
  if (me.account) redirect("/");
  const districts = await getDistricts();

  return (
    <Screen title={text.signup.title}>
      <ActionForm action={createAccount} submit={text.signup.create}>
        <Field label={text.signup.fullName} htmlFor="fullName">
          <input id="fullName" name="fullName" required className={inputStyle} />
        </Field>
        <Field label={text.signup.firmName} htmlFor="firmName">
          <input id="firmName" name="firmName" className={inputStyle} />
        </Field>
        <Field label={text.signup.role} htmlFor="role">
          <select id="role" name="role" required defaultValue="retailer" className={inputStyle}>
            {ROLES.map((r) => <option key={r} value={r}>{text.roles[r]}</option>)}
          </select>
        </Field>
        <p className="text-sm">{text.signup.roleNote}</p>
        <Field label={text.signup.district} htmlFor="regionId">
          <DistrictSelect id="regionId" name="regionId" districts={districts} />
        </Field>
        <label className="flex items-center gap-2"><input type="checkbox" name="terms" className="size-5" />{text.signup.terms}</label>
        <label className="flex items-center gap-2"><input type="checkbox" name="privacy" className="size-5" />{text.signup.privacy}</label>
      </ActionForm>
    </Screen>
  );
}
