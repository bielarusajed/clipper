// Generates public/og.png, the 1200×630 link-preview image (LinkedIn, Slack, iMessage…),
// from the dark hero screenshot. Run on macOS after changing the screenshot:
//   node scripts/make-og.mjs
// Text uses Helvetica Neue from the system, so the output is committed rather than built.
import sharp from 'sharp';

const W = 1200;
const H = 630;
const BG = '#0f1623';
const shot = new URL('../src/assets/screens/editor-dark.png', import.meta.url).pathname;
const out = new URL('../public/og.png', import.meta.url).pathname;

// The capture is the window on its blurred backdrop; scale it so the window fills the right side
// and runs off the bottom-right edge.
const shotWidth = 900;
const screenshot = await sharp(shot).resize({ width: shotWidth }).png().toBuffer();
const { height: shotHeight = 0 } = await sharp(screenshot).metadata();
const mask = Buffer.from(
  `<svg width="${shotWidth}" height="${shotHeight}"><rect width="${shotWidth}" height="${shotHeight}" rx="22" fill="#fff"/></svg>`,
);
const rounded = await sharp(screenshot)
  .composite([{ input: mask, blend: 'dest-in' }])
  .png()
  .toBuffer();

const text = Buffer.from(`<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
  <style>
    .brand { font: 700 30px 'Helvetica Neue', Helvetica, sans-serif; fill: #e9eef5; }
    .h { font: 700 66px 'Helvetica Neue', Helvetica, sans-serif; fill: #ffffff; letter-spacing: -2.4px; }
    .sub { font: 400 24px 'Helvetica Neue', Helvetica, sans-serif; fill: #9aa6b6; }
  </style>
  <rect x="60" y="56" width="44" height="44" rx="10" fill="#1754a6"/>
  <rect x="69" y="66" width="26" height="20" rx="1.5" fill="none" stroke="#fff" stroke-width="1.6"/>
  <path d="M69 70v12M95 70v12" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/>
  <path d="M79 71.5v9l8-4.5z" fill="#fff"/>
  <text x="118" y="89" class="brand">Clipper</text>
  <text x="60" y="210" class="h">Cut on</text>
  <text x="60" y="282" class="h">the frame</text>
  <text x="60" y="354" class="h">you meant.</text>
  <text x="60" y="430" class="sub">Frame-exact video clips</text>
  <text x="60" y="464" class="sub">on your Mac. Free and</text>
  <text x="60" y="498" class="sub">open source.</text>
  <rect x="60" y="540" width="64" height="5" rx="2.5" fill="#f2a20c"/>
</svg>`);

await sharp({ create: { width: W, height: H, channels: 4, background: BG } })
  .composite([
    { input: rounded, left: 400, top: 120 },
    { input: text, left: 0, top: 0 },
  ])
  .flatten({ background: BG })
  .png({ compressionLevel: 9 })
  .toFile(out);
console.log('wrote', out);
