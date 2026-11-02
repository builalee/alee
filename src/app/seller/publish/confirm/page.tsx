import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { Card, Screen } from "@/components/ui";
import { getFamily, getPublishLines, getPublishPreview, requireAccount } from "@/lib/api/queries";
import { publishToday } from "@/lib/api/trade";
import { formatRupees, formatSignedRupees, readAmount } from "@/lib/money";
import { text } from "@/lib/text";

/**
 * The confirmation: each line's final rate in every area, worked out by the
 * rate engine from the rates he entered. Confirm sends exactly these rates.
 */
export default async function ConfirmPage({ searchParams }: { searchParams: Promise<Record<string, string>> }) {
  const query = await searchParams;
  await requireAccount();
  const family = await getFamily();
  if (!family) redirect("/seller");
  const lines = (await getPublishLines(family.id)).filter((l) => l.move_status !== "not_quoting");

  const entered = lines.map((l) => ({ line: l, rate: readAmount(query[`rate_${l.brand_id}`] ?? null) }));
  const valid = entered.every((e) => e.rate !== "empty" && e.rate !== "invalid" && Number(e.rate) > 0);

  if (!valid || lines.length === 0) {
    return (
      <Screen title={text.publish.confirmTitle} back="/seller/publish">
        <p role="alert" className="text-red-700 dark:text-red-400">{text.publish.needRates}</p>
        <Link href="/seller/publish" className="underline">{text.publish.back}</Link>
      </Screen>
    );
  }

  const previews = await Promise.all(entered.map((e) => getPublishPreview(e.line.brand_id, family.id, e.rate)));

  return (
    <Screen title={text.publish.confirmTitle} back="/seller/publish">
      <p>{text.publish.confirmIntro}</p>
      {entered.map(({ line, rate }, i) => {
        const preview = previews[i];
        const areas = [...new Set(preview.lines.map((l) => l.area_name ?? ""))];
        const missing = [...new Set(preview.lines.flatMap((l) => l.missing ?? []))];
        return (
          <Card key={line.brand_id}>
            <h2 className="font-semibold">{line.line_name}</h2>
            <p className="text-lg">{text.publish.basicRate}: {formatRupees(rate)} {text.publish.per} {text.products[line.current_unit]}</p>
            {preview.error && <p role="alert" className="text-red-700 dark:text-red-400">{preview.error}</p>}
            {missing.length > 0 && (
              <div className="text-red-700 dark:text-red-400">
                <p className="font-medium">{text.publish.missing}</p>
                <ul className="list-disc pl-5">{missing.map((m) => <li key={m}>{m}</li>)}</ul>
              </div>
            )}
            {areas.map((area) => {
              const rows = preview.lines.filter((l) => (l.area_name ?? "") === area);
              // Each place shows its difference, so the overview needs no opening.
              const differences = [...new Set(rows.filter((r) => r.area_difference !== null).map((r) => Number(r.area_difference)))];
              const differenceText = differences.length === 0 ? text.publish.diffNotSet
                : differences.length > 1 ? text.publish.variesByGrade
                : differences[0] === 0 ? text.publish.sameAsBase : formatSignedRupees(String(differences[0]));
              return (
                <details key={area} className="border-t border-current/15 pt-2">
                  <summary className="font-medium">
                    {area || text.publish.everywhere} · {differenceText} · {rows.length} {text.publish.rates}
                  </summary>
                  <table className="w-full text-left">
                    <tbody>
                      {rows.map((r, j) => (
                        <tr key={j} className="border-t border-current/10">
                          <td className="py-1 pr-2">{r.grade} · {r.size}</td>
                          <td className="py-1 text-right">
                            {r.area_rate_text ?? r.message}
                            {r.area_discount_text && <span className="block text-sm">{r.area_discount_text}</span>}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </details>
              );
            })}
          </Card>
        );
      })}
      <ActionForm action={publishToday} submit={text.publish.confirm}>
        {/* Made once per screen, so a second tap is the same publish (decision 16.10). */}
        <input type="hidden" name="key" value={randomUUID()} />
        {entered.map(({ line, rate }) => (
          <span key={line.brand_id}>
            <input type="hidden" name="brandId" value={line.brand_id} />
            <input type="hidden" name={`rate_${line.brand_id}`} value={rate} />
          </span>
        ))}
      </ActionForm>
      <Link href="/seller/publish" className="text-center underline">{text.publish.back}</Link>
    </Screen>
  );
}
