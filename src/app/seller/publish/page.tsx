import Link from "next/link";
import { redirect } from "next/navigation";
import { PublishForm } from "@/components/publish-form";
import { Screen } from "@/components/ui";
import { getFamily, getProfile, getPublishLines, requireAccount } from "@/lib/api/queries";
import { text } from "@/lib/text";

export default async function PublishPage({ searchParams }: { searchParams: Promise<{ published?: string }> }) {
  const { published } = await searchParams;
  const me = await requireAccount();
  const [profile, family] = await Promise.all([getProfile(me.id), getFamily()]);
  if (!profile || !family) redirect("/seller");
  const lines = await getPublishLines(family.id);

  return (
    <Screen title={text.nav.publish} back="/">
      {published && <p role="status" className="font-medium text-green-700 dark:text-green-400">{text.publish.published}</p>}
      {lines.length === 0 ? (
        <p>{text.publish.nothing} <Link href="/seller" className="underline">{text.nav.sellerSetup}</Link></p>
      ) : (
        <>
          <p>{text.publish.intro}</p>
          <PublishForm lines={lines} />
        </>
      )}
    </Screen>
  );
}
