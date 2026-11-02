import { Card, Screen } from "@/components/ui";
import { getMyEnquiries, requireAccount } from "@/lib/api/queries";
import { formatWhen } from "@/lib/dates";
import { text } from "@/lib/text";

export default async function MyEnquiriesPage({ searchParams }: { searchParams: Promise<{ sent?: string }> }) {
  const { sent } = await searchParams;
  await requireAccount();
  const enquiries = await getMyEnquiries();

  return (
    <Screen title={text.enquiry.mine} back="/">
      {sent && <p role="status" className="font-medium text-green-700 dark:text-green-400">{text.enquiry.sent}</p>}
      {enquiries.length === 0 && <p>{text.enquiry.none}</p>}
      {enquiries.map((e) => (
        <Card key={e.id}>
          <p className="font-semibold">{e.seller}: {e.brand}</p>
          <p className="text-sm">{formatWhen(e.createdAt, false)}</p>
          {e.recipient && <p className="text-sm">{text.enquiry.goesTo} {e.recipient}</p>}
          {e.quantity && <p>{e.quantity}</p>}
          {e.note && <p>{e.note}</p>}
          {e.afterClose && <p className="font-medium">{text.enquiry.afterClose}</p>}
        </Card>
      ))}
    </Screen>
  );
}
