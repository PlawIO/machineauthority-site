// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://machineauthority.org',
  output: 'static',
  trailingSlash: 'ignore',
  integrations: [sitemap()],
  compressHTML: true,
});
