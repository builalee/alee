import Link from "next/link";
import { Card } from "@/components/ui";
import type { SellerRates } from "@/lib/api/queries";
import { formatTime, formatWhen } from "@/lib/dates";
import { text } from "@/lib/text";

/**
 * One seller's brand line as a buyer sees it: final figures from the rate
 * engine only, with "Updated [time]" large, greyed when from an earlier day.
 */
export function RateCard({ rates, showSeller }: { rates: SellerRates; showSeller: boolean }) {
  const first = rates.lines[0];
  const priced = rates.lines.filter((l) => l.area_rate_text || l.ex_works_text);
  const messages = [...new Set(rates.lines.filter((l) => !l.area_rate_text && !l.ex_works_text && l.message)
    .map((l) => l.message as string))];
  const isOld = first?.published_at && !first.published_today;

  return (
    <Card>
      <div className="flex flex-col gap-1">
        {showSeller && (
          <Link href={`/sellers/${rates.sellerId}`} className="text-lg font-semibold underline">{rates.storeName}</Link>
        )}
        <p className="font-medium">{first?.brand_name}</p>
        {first?.tag && <p className="text-sm font-medium">{first.tag}</p>}
      </div>

      {first?.published_at && (
        <div className={isOld ? "opacity-50" : ""}>
          <p className="text-2xl font-bold">
            {text.buyer.updated} {formatWhen(first.published_at, Boolean(first.published_today))}
          </p>
          {isOld && <p className="text-sm">{text.buyer.oldRate}</p>}
        </div>
      )}
      {first?.market === "closed" && first.closed_at && (
        <p className="font-medium">{text.buyer.marketClosed} {formatTime(first.closed_at)}</p>
      )}

      {priced.length > 0 && (
        <table className={`w-full text-left ${isOld ? "opacity-50" : ""}`}>
          <tbody>
            {priced.map((l) => (
              <tr key={`${l.product_id}-${l.size_id}`} className="border-t border-current/15 align-top">
                <td className="py-2 pr-2">{l.grade} · {l.size}</td>
                <td className="py-2 text-right">
                  {l.area_rate_text ? (
                    <>
                      <span className="text-lg font-semibold">{l.area_rate_text}</span>
                      <span className="block text-sm">{l.area_rate_label}</span>
                      {l.area_discount_text && <span className="block text-sm">{l.area_discount_text}</span>}
                    </>
                  ) : (
                    <>
                      <span className="text-lg font-semibold">{l.ex_works_text}</span>
                      <span className="block text-sm">{l.ex_works_label}</span>
                      {l.ex_works_discount_text && <span className="block text-sm">{l.ex_works_discount_text}</span>}
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {messages.map((m) => <p key={m}>{m}</p>)}

      <Link href={`/sellers/${rates.sellerId}/enquiry?brand=${rates.brandId}`}
        className="rounded-lg border border-current/40 px-3 py-3 text-center font-medium">
        {text.buyer.sendEnquiry}
      </Link>
    </Card>
  );
}
