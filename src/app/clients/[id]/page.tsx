import { ActionForm } from "@/components/action-form";
import { ClientFields } from "@/components/client-fields";
import { ContactButtons } from "@/components/contact-buttons";
import { FollowUpCard } from "@/components/follow-up-card";
import { Card, Field, inputStyle, Screen } from "@/components/ui";
import { addFollowUp, logVisit, saveClient } from "@/lib/api/clients";
import { getClientBook, getDistricts, requireAccount } from "@/lib/api/queries";
import { formatWhen, todayInIndia } from "@/lib/dates";
import { formatPhone } from "@/lib/phone";
import { text } from "@/lib/text";

export default async function ClientPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  await requireAccount();
  const [book, districts] = await Promise.all([getClientBook(id), getDistricts()]);
  if (!book) {
    return <Screen title={text.clients.title} back="/clients"><p>{text.clients.notFound}</p></Screen>;
  }
  const { client, followUps, activity } = book;
  const district = districts.find((d) => d.id === client.region_id)?.name;

  return (
    <Screen title={client.name} back="/clients">
      <p>
        {[client.client_type && text.clients.types[client.client_type], district, client.phone && formatPhone(client.phone)]
          .filter(Boolean).join(" · ")}
      </p>
      {client.note && <p className="rounded-lg bg-current/5 p-3">{client.note}</p>}
      {client.phone && <ContactButtons clientId={client.id} phone={client.phone} />}
      <details className="rounded-lg border border-current/20 p-3">
        <summary className="font-medium">{text.clients.visit}</summary>
        <ActionForm action={logVisit} submit={text.clients.visit}>
          <input type="hidden" name="clientId" value={client.id} />
          <Field label={text.clients.visitNote} htmlFor="visitNote">
            <textarea id="visitNote" name="note" rows={2} maxLength={1000} className={inputStyle} />
          </Field>
        </ActionForm>
      </details>

      <Card>
        <h2 className="text-xl font-semibold">{text.clients.followUps}</h2>
        {followUps.length === 0 && <p>{text.clients.noFollowUps}</p>}
        {followUps.map((f) => <FollowUpCard key={f.id} followUp={{ ...f, client_id: client.id }} />)}
        <details>
          <summary className="font-medium">{text.clients.addFollowUp}</summary>
          <ActionForm action={addFollowUp} submit={text.clients.saveFollowUp}>
            <input type="hidden" name="clientId" value={client.id} />
            <Field label={text.clients.date} htmlFor="dueOn">
              <input id="dueOn" name="dueOn" type="date" required min={todayInIndia()} className={inputStyle} />
            </Field>
            <Field label={text.clients.followUpNote} htmlFor="followNote">
              <input id="followNote" name="note" maxLength={1000} className={inputStyle} />
            </Field>
          </ActionForm>
        </details>
      </Card>

      <Card>
        <h2 className="text-xl font-semibold">{text.clients.history}</h2>
        {activity.length === 0 && <p>{text.clients.noHistory}</p>}
        <ul className="flex flex-col gap-2">
          {activity.map((a) => (
            <li key={a.id} className="border-t border-current/10 pt-2">
              <span className="font-medium">{text.clients.kinds[a.kind]}</span> · {formatWhen(a.created_at, false)}
              {a.note && <span className="block">{a.note}</span>}
            </li>
          ))}
        </ul>
      </Card>

      <details className="rounded-lg border border-current/20 p-3">
        <summary className="font-medium">{text.clients.edit}</summary>
        <ActionForm action={saveClient} submit={text.clients.save} startSaved>
          <ClientFields client={client} districts={districts} />
        </ActionForm>
      </details>
    </Screen>
  );
}
