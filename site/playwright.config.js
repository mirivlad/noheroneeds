const { defineConfig } = require('@playwright/test');
module.exports = defineConfig({
  testDir: './tests/browser',
  workers: 2,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: { channel: 'chromium', baseURL: 'http://127.0.0.1:18764/noheroneeds/', screenshot: 'only-on-failure', trace: 'retain-on-failure' },
  webServer: {
    command: 'python3 ../tools/site/serve.py --port 18764',
    url: 'http://127.0.0.1:18764/noheroneeds/',
    reuseExistingServer: false,
  },
});
