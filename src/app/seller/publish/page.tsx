import Link from "next/link";
import { redirect } from "next/navigation";
import { PublishForm } from "@/components/publish-form";
import { Screen } from "@/components/ui";
import { getFamily, getProfile, getPublishLines, requireAccount } from "@/lib/api/queries";
import { isTodayInIndia } from "@/lib/dates";
import { text } from "@/lib/text";

export default async function PublishPage({ searchParams }: { searchParams: Promise<{ published?: string }> }) {
  const { published } = await searchParams;
  const me = await requireAccount();
  const [profile, family] = await Promise.all([getProfile(me.id), getFamily()]);
  if (!profile || !family) redirect("/seller");
  const lines = await getPublishLines(family.id);
  // Every line he quotes already went out today: the boxes start locked.
  const quoting = lines.filter((l) => l.move_status !== "not_quoting");
  const publishedToday = quoting.length > 0
    && quoting.every((l) => l.move_status === "move" && l.last_published_at && isTodayInIndia(l.last_published_at));

  return (
    <Screen title={text.nav.publish} back="/">
      {published && <p role="status" className="font-medium text-green-700 dark:text-green-400">{text.publish.published}</p>}
      {lines.length === 0 ? (
        <p>{text.publish.nothing} <Link href="/seller" className="underline">{text.nav.sellerSetup}</Link></p>
      ) : (
        <>
          {!publishedToday && <p>{text.publish.intro}</p>}
          <PublishForm lines={lines} publishedToday={publishedToday} />
        </>
      )}
    </Screen>
  );
}
