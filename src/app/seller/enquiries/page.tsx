import { Card, Screen } from "@/components/ui";
import { getReceivedEnquiries, requireAccount } from "@/lib/api/queries";
import { formatWhen } from "@/lib/dates";
import { text } from "@/lib/text";

export default async function ReceivedEnquiriesPage() {
  await requireAccount();
  const enquiries = await getReceivedEnquiries();

  return (
    <Screen title={text.enquiry.received} back="/">
      {enquiries.length === 0 && <p>{text.enquiry.none}</p>}
      {enquiries.map((e) => (
        <Card key={e.id}>
          <p className="font-semibold">
            {e.brand_name}{e.grade && ` · ${e.grade}`}{e.size && ` · ${e.size}`}
          </p>
          <p className="text-sm">{formatWhen(e.created_at, false)}</p>
          {e.quantity && <p>{e.quantity} {e.quantity_unit}</p>}
          {e.note && <p>{e.note}</p>}
          <p>{text.enquiry.fromArea}: {e.area_name} · {text.roles[e.buyer_type]}</p>
          {e.buyer_name ? (
            <p className="font-medium">
              {e.buyer_name}
              {e.buyer_phone && <> · <a href={`tel:${e.buyer_phone}`} className="underline">{text.enquiry.call} {e.buyer_phone}</a></>}
            </p>
          ) : (
            <p>{text.enquiry.hiddenBuyer} · {e.buyer_recent} {text.enquiry.recent}</p>
          )}
          {e.via_seller && <p className="text-sm">{text.enquiry.via} {e.via_seller}</p>}
          {e.received_after_close && <p className="font-medium">{text.enquiry.afterClose}</p>}
        </Card>
      ))}
    </Screen>
  );
}
