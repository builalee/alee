import Link from "next/link";
import { FollowUpCard } from "@/components/follow-up-card";
import { Card, inputStyle, Screen } from "@/components/ui";
import { getClients, getDistricts, getFollowUpsDue, requireAccount } from "@/lib/api/queries";
import { formatPhone } from "@/lib/phone";
import { text } from "@/lib/text";

export default async function ClientBookPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q } = await searchParams;
  await requireAccount();
  const [due, clients, districts] = await Promise.all([getFollowUpsDue(), getClients(q), getDistricts()]);
  const districtName = new Map(districts.map((d) => [d.id, d.name]));

  return (
    <Screen title={text.clients.title} back="/">
      <p className="text-sm">{text.clients.private}</p>
      <Card>
        <h2 className="text-xl font-semibold">{text.clients.today}</h2>
        {due.length === 0 && <p>{text.clients.todayNone}</p>}
        {due.map((f) => <FollowUpCard key={f.id} followUp={f} clientName={f.client_name} phone={f.phone} />)}
      </Card>
      <Link href="/clients/new" className="rounded-lg bg-foreground px-3 py-3 text-center text-lg font-semibold text-background">
        {text.clients.add}
      </Link>
      <form className="flex gap-2" role="search">
        <label htmlFor="q" className="sr-only">{text.clients.search}</label>
        <input id="q" name="q" defaultValue={q ?? ""} placeholder={text.clients.search} className={inputStyle} />
        <button type="submit" className="rounded-lg border border-current/40 px-4 font-medium">{text.clients.searchButton}</button>
      </form>
      {clients.length === 0 && <p>{q ? text.clients.noMatch : text.clients.noClients}</p>}
      <ul className="flex flex-col gap-2">
        {clients.map((c) => (
          <li key={c.id}>
            <Link href={`/clients/${c.id}`} className="flex flex-col rounded-lg border border-current/20 p-3">
              <span className="text-lg font-semibold">{c.name}</span>
              <span className="text-sm">
                {[c.client_type && text.clients.types[c.client_type], c.region_id && districtName.get(c.region_id),
                  c.phone && formatPhone(c.phone)].filter(Boolean).join(" · ")}
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </Screen>
  );
}
