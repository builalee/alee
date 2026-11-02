import { ActionForm } from "@/components/action-form";
import { ClientFields } from "@/components/client-fields";
import { Screen } from "@/components/ui";
import { saveClient } from "@/lib/api/clients";
import { getDistricts, requireAccount } from "@/lib/api/queries";
import { text } from "@/lib/text";

export default async function NewClientPage() {
  await requireAccount();
  const districts = await getDistricts();
  return (
    <Screen title={text.clients.add} back="/clients">
      <p className="text-sm">{text.clients.private}</p>
      <ActionForm action={saveClient} submit={text.clients.save}>
        <ClientFields districts={districts} />
      </ActionForm>
    </Screen>
  );
}
