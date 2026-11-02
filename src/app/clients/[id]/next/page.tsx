import Link from "next/link";
import { ActionForm } from "@/components/action-form";
import { FollowUpCard } from "@/components/follow-up-card";
import { Field, inputStyle, Screen } from "@/components/ui";
import { addFollowUp } from "@/lib/api/clients";
import { getClientBook, requireAccount } from "@/lib/api/queries";
import { todayInIndia } from "@/lib/dates";
import { text } from "@/lib/text";

/**
 * Asked straight after a call, a visit or "Done": the next follow-up date.
 * He can skip it, but must choose to (decision 11.1). Later follow-ups stay,
 * with a one-tap option to close them too.
 */
export default async function NextFollowUpPage({ params, searchParams }: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ closed?: string }>;
}) {
  const [{ id }, { closed }] = await Promise.all([params, searchParams]);
  await requireAccount();
  const book = await getClientBook(id);
  if (!book) {
    return <Screen title={text.clients.nextTitle} back="/clients"><p>{text.clients.notFound}</p></Screen>;
  }
  const closedCount = Number(closed) || 0;

  return (
    <Screen title={`${text.clients.nextTitle}: ${book.client.name}`}>
      {closedCount > 0 && (
        <p role="status" className="font-medium text-green-700 dark:text-green-400">{text.clients.closedSome} {closedCount}</p>
      )}
      <p className="text-lg">{text.clients.nextAsk}</p>
      <ActionForm action={addFollowUp} submit={text.clients.saveNext}>
        <input type="hidden" name="clientId" value={id} />
        <Field label={text.clients.date} htmlFor="dueOn">
          <input id="dueOn" name="dueOn" type="date" required min={todayInIndia()} className={inputStyle} />
        </Field>
        <Field label={text.clients.followUpNote} htmlFor="followNote">
          <input id="followNote" name="note" maxLength={1000} className={inputStyle} />
        </Field>
      </ActionForm>
      <Link href={`/clients/${id}`} className="rounded-lg border border-current/40 px-3 py-3 text-center text-lg font-medium">
        {text.clients.noNext}
      </Link>
      {book.followUps.length > 0 && (
        <section className="flex flex-col gap-2">
          <h2 className="font-semibold">{text.clients.laterOnes}</h2>
          {book.followUps.map((f) => (
            <FollowUpCard key={f.id} followUp={{ ...f, client_id: id }} closedBefore={closedCount} />
          ))}
        </section>
      )}
    </Screen>
  );
}
