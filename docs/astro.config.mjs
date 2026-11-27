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
      head: [
        {
          tag: 'script',
          attrs: { type: 'module' },
          content: `
const renderMermaid = async () => {
  const blocks = [...document.querySelectorAll('pre[data-language="mermaid"]')];
  if (blocks.length === 0) return;
  try {
    const { default: mermaid } = await import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs');
    const isLight = document.documentElement.dataset.theme === 'light';
    mermaid.initialize({ startOnLoad: false, theme: isLight ? 'default' : 'dark', securityLevel: 'strict' });
    for (let i = 0; i < blocks.length; i++) {
      const pre = blocks[i];
      const source = pre.textContent ?? '';
      const frame = pre.closest('.expressive-code') ?? pre;
      const { svg } = await mermaid.render('cp-mermaid-' + i + '-' + Date.now(), source);
      const wrap = document.createElement('figure');
      wrap.className = 'cp-diagram cp-mermaid';
      wrap.innerHTML = svg;
      frame.replaceWith(wrap);
    }
  } catch (err) {
    console.warn('mermaid render skipped:', err);
  }
};
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', renderMermaid);
} else {
  renderMermaid();
}
          `.trim(),
        },
      ],
      sidebar: [
        {
          label: 'Start Here',
          items: [{ label: 'Getting Started', slug: 'getting-started' }],
        },
        {
          label: 'Coding Factory',
          items: [
            { label: 'Lighthouse Audit Report', slug: 'factory/audit' },
            { label: 'Mythical History', slug: 'history' },
            { label: 'Engineering Wiki', autogenerate: { directory: 'wiki' } },
          ],
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
