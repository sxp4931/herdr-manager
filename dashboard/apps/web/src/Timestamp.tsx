import { formatAbsolute } from "./format.js";

/** A readable America/New_York time that keeps the exact instant machine-readable and on hover. */
export function Timestamp({ iso }: { iso: string | null }) {
  if (iso === null) return <>Unknown</>;
  return (
    <time dateTime={iso} title={iso}>
      {formatAbsolute(iso)}
    </time>
  );
}
