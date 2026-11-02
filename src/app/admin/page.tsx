import { ActionForm } from "@/components/action-form";
import { Card, Screen } from "@/components/ui";
import { decide } from "@/lib/api/admin";
import { getAdminQueue, requireAdmin } from "@/lib/api/queries";
import { text } from "@/lib/text";

function Row({ kind, id, label }: { kind: string; id: string; label: string }) {
  return (
    <div className="flex flex-col gap-2 border-t border-current/15 pt-3">
      <p>{label}</p>
      <div className="grid grid-cols-2 gap-2">
        {(["yes", "no"] as const).map((approve) => (
          <ActionForm key={approve} action={decide} secondary submit={approve === "yes" ? text.common.approve : text.common.refuse}>
            <input type="hidden" name="kind" value={kind} />
            <input type="hidden" name="id" value={id} />
            <input type="hidden" name="approve" value={approve} />
          </ActionForm>
        ))}
      </div>
    </div>
  );
}

export default async function AdminPage() {
  await requireAdmin();
  const queue = await getAdminQueue();

  return (
    <Screen title={text.admin.title} back="/">
      <Card>
        <h2 className="font-semibold">{text.admin.roles}</h2>
        {queue.roles.length === 0 && <p>{text.common.none}</p>}
        {queue.roles.map((r) => (
          <Row key={r.id} kind="decide_role_request" id={r.id} label={`${r.who}: ${text.roles[r.role]}`} />
        ))}
      </Card>
      <Card>
        <h2 className="font-semibold">{text.admin.brands}</h2>
        {queue.brands.length === 0 && <p>{text.common.none}</p>}
        {queue.brands.map((b) => <Row key={b.id} kind="decide_brand" id={b.id} label={b.name} />)}
      </Card>
      <Card>
        <h2 className="font-semibold">{text.admin.claims}</h2>
        {queue.claims.length === 0 && <p>{text.common.none}</p>}
        {queue.claims.map((c) => (
          <Row key={c.id} kind="decide_brand_claim" id={c.id} label={`${c.brand} ${text.admin.claimBy} ${c.who}`} />
        ))}
      </Card>
    </Screen>
  );
}
