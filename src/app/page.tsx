import { text } from "@/lib/text";

export default function Home() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-3 px-4 py-16 text-center">
      <h1 className="text-5xl font-bold tracking-tight">{text.app.name}</h1>
      <p className="max-w-xs text-lg">{text.app.tagline}</p>
      <p className="text-sm opacity-70">{text.home.comingSoon}</p>
    </main>
  );
}
