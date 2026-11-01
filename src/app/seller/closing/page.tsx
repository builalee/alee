import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { Field, inputStyle, Screen } from "@/components/ui";
import { getProfile, requireAccount } from "@/lib/api/queries";
import { saveClosingTime } from "@/lib/api/seller";
import { toTimeInput } from "@/lib/dates";
import { text } from "@/lib/text";

const SUGGESTED_CLOSE = "18:00";

export default async function ClosingPage() {
  const me = await requireAccount();
  const profile = await getProfile(me.id);
  if (!profile) redirect("/seller");

  return (
    <Screen title={text.seller.stepClosing} back="/seller">
      <ActionForm action={saveClosingTime} submit={text.closing.accept} startSaved={Boolean(profile.market_close_time)}>
        <Field label={text.closing.label} htmlFor="closeTime">
          <input id="closeTime" name="closeTime" type="time" required className={inputStyle}
            defaultValue={toTimeInput(profile.market_close_time) || SUGGESTED_CLOSE} />
        </Field>
      </ActionForm>
    </Screen>
  );
}
