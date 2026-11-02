import { text } from "@/lib/text";

export default function Loading() {
  return <p role="status" className="flex flex-1 items-center justify-center p-8 text-lg">{text.common.wait}</p>;
}
