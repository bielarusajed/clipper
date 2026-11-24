import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://clipper.bielarusajed.gay',
  vite: { plugins: [tailwindcss()] },
});
