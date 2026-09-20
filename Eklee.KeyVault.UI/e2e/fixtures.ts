import { expect, test as base, type TestInfo } from '@playwright/test';

type ReportUrlFixture = {
  reportTestUrl: void;
};

function addTestUrlAnnotation(testInfo: TestInfo): void {
  const configuredBaseUrl = testInfo.project.use.baseURL;

  if (!configuredBaseUrl) {
    return;
  }

  const testUrl = new URL(configuredBaseUrl);
  testUrl.username = '';
  testUrl.password = '';

  testInfo.annotations.push({
    type: 'Test URL',
    description: testUrl.toString(),
  });
}

export const test = base.extend<ReportUrlFixture>({
  reportTestUrl: [
    async ({}, use, testInfo) => {
      addTestUrlAnnotation(testInfo);
      await use();
    },
    { auto: true },
  ],
});

export { expect };