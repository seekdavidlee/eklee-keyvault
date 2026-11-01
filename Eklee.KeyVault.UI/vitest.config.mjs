import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config.ts';

export default defineConfig(async (environment) => mergeConfig(
  typeof viteConfig === 'function' ? await viteConfig(environment) : await viteConfig,
  defineConfig({
    test: {
      environment: 'jsdom',
      include: ['src/**/*.test.{ts,tsx}', 'src/**/*.spec.{ts,tsx}'],
      setupFiles: ['./.frontend-test-setup.mjs'],
      clearMocks: true,
      restoreMocks: true,
    },
  }),
));
