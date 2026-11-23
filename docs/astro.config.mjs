import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://smithersai.github.io',
  base: '/claude-p',
  integrations: [
    starlight({
      title: 'claude-p',
      favicon: '/favicon.svg',
      description:
        'Emulates claude -p by driving the interactive claude UI inside an in-process zmux PTY session. text and json match claude -p; stream-json is filtered transcript JSONL plus a claude -p-shaped result.',
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/smithersai/claude-p',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/smithersai/claude-p/edit/main/docs/',
      },
      customCss: ['./src/styles/custom.css'],
      sidebar: [
        {
          label: 'Start Here',
          items: [{ label: 'Getting Started', slug: 'getting-started' }],
        },
        {
          label: 'Tutorials',
          autogenerate: { directory: 'tutorials' },
        },
        {
          label: 'How-to Guides',
          autogenerate: { directory: 'guides' },
        },
        {
          label: 'How It Works',
          autogenerate: { directory: 'internals' },
        },
        {
          label: 'Reference',
          autogenerate: { directory: 'reference' },
        },
      ],
    }),
  ],
});
