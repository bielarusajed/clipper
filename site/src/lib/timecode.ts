const pad = (n: number, width = 2) => String(n).padStart(width, '0');

/** Formats seconds as hh:mm:ss.sss, the way Clipper shows Start and End. */
export function timecode(seconds: number): string {
  const ms = Math.round(seconds * 1000);
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor(ms / 60_000) % 60;
  const s = Math.floor(ms / 1000) % 60;
  return `${pad(h)}:${pad(m)}:${pad(s)}.${pad(ms % 1000, 3)}`;
}
