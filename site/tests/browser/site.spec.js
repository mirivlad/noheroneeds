const { test, expect } = require('@playwright/test');

test.beforeEach(async ({ page }) => {
  page.errors = [];
  page.on('pageerror', error => page.errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') page.errors.push(message.text()); });
});
test.afterEach(async ({ page }) => expect(page.errors).toEqual([]));

test('home and section navigation work under the repository subpath', async ({ page }) => {
  await page.goto('./');
  await expect(page.locator('h1')).toBeVisible();
  await expect(page.locator('.hero img')).toBeVisible();
  await page.screenshot({ path: 'test-results/home-desktop.png' });
  await page.locator('#main-nav').getByRole('link', { name: 'Энциклопедия' }).click();
  await expect(page.locator('.item-card').first()).toBeVisible();
  await page.locator('#main-nav').getByRole('link', { name: 'Как играть' }).click();
  await expect(page.locator('.guide-article.active')).toBeVisible();
  await page.screenshot({ path: 'test-results/guides-desktop.png', fullPage: true });
});

test('iron links connect ore, smelting, ingot, sword and smith', async ({ page }) => {
  await page.goto('wiki.html?item=base%3Airon_ore');
  const detail = page.locator('#wiki-detail');
  for (const id of ['base:smelt_iron', 'base:iron_ingot', 'base:forge_iron_sword', 'base:smith']) {
    await detail.locator(`[data-item="${id}"]`).first().click();
    await expect(detail.locator('code')).toHaveText(id);
  }
  await expect(detail).toContainText('55');
  await expect(detail).toContainText('доверие 1');
  await page.screenshot({ path: 'test-results/wiki-smith.png', fullPage: true });
});

test('global search includes all guides and generated content on every page', async ({ page }) => {
  await page.goto('./');
  await page.locator('#open-search').click();
  await page.locator('#global-search').fill('таверны');
  await page.locator('#global-results a[href="guides.html#hospitality"]').click();
  await expect(page.locator('#hospitality')).toBeVisible();
  await page.locator('#open-search').click();
  await page.locator('#global-search').fill('железная руда');
  await page.locator('#global-results a[href$="base%3Airon_ore"]').click();
  await expect(page.locator('#wiki-detail code')).toHaveText('base:iron_ore');
});

test('hospitality guide has live terms and crosslinks to the host and services', async ({ page }) => {
  await page.goto('guides.html#hospitality');
  const guide = page.locator('#hospitality');
  await expect(guide).toBeVisible();
  await expect(guide).toContainText('6 монет на 12');
  await expect(guide).toContainText('15 монет на 24');
  await expect(guide).toContainText('награда 12');
  await expect(guide).toContainText('ещё не созданных');
  await page.screenshot({ path: 'test-results/hospitality-desktop.png', fullPage: true });
  await guide.locator('a[href$="base%3Ainnkeeper"]').first().click();
  await page.locator('#wiki-detail [data-item="base:inn_services"]').first().click();
  await expect(page.locator('#wiki-detail')).toContainText('Ночлег');
  await page.locator('#wiki-detail [data-item="base:bread"]').first().click();
  await page.locator('#wiki-detail [data-item="base:bake_bread"]').first().click();
  await page.locator('#wiki-detail [data-item="base:wheat"]').first().click();
  await expect(page.locator('#wiki-detail')).toContainText('Пшеница');
});

test('missing records and empty search results are explained', async ({ page, request }) => {
  await page.goto('wiki.html?item=base%3Ano_such_record');
  await expect(page.locator('#wiki-detail')).toContainText('Запись не найдена');
  await page.locator('#wiki-search').fill('нет-такой-вещи-12345');
  await expect(page.locator('#wiki-items')).toContainText('Ничего не найдено');
  expect((await request.get('missing.html')).status()).toBe(404);
});

test('release selection stays on 0.13 and then on the latest publication at the bottom', async ({ page }) => {
  await page.goto('updates.html');
  const links = page.locator('.release-index-link');
  await expect(links.first()).toBeVisible();
  await links.filter({ hasText: 'v0.13.0' }).click();
  await page.waitForTimeout(1400);
  await expect(links.filter({ hasText: 'v0.13.0' })).toHaveAttribute('aria-current', 'location');
  const last = links.last();
  const hash = await last.getAttribute('href');
  await last.click();
  await page.waitForTimeout(1400); // the deliberately locked smooth-scroll selection expires
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  await expect(last).toHaveAttribute('aria-current', 'location');
  await expect(page.locator(hash + ' details')).toHaveAttribute('open', '');
  await expect(page.locator(hash + ' a[target="_blank"]')).toHaveAttribute('href', /github\.com\/mirivlad\/noheroneeds\/releases\/tag\/v\d+\.\d+\.\d+$/);
  await page.screenshot({ path: 'test-results/updates-latest.png', fullPage: true });
});

test('mobile navigation and item detail fit a narrow screen', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('./');
  await page.locator('#menu-toggle').click();
  await expect(page.locator('#menu-toggle')).toHaveAttribute('aria-expanded', 'true');
  await page.locator('#main-nav').getByRole('link', { name: 'Энциклопедия' }).click();
  await page.locator('#wiki-search').fill('меч');
  await page.locator('.item-card[data-item="base:iron_sword"]').click();
  await expect(page.locator('#wiki-detail')).toBeVisible();
  await expect.poll(() => page.locator('#wiki-detail').evaluate(el => {
    const rect = el.getBoundingClientRect();
    return rect.left >= -1 && rect.right <= innerWidth + 1 && rect.width >= innerWidth - 2;
  })).toBeTruthy();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBeTruthy();
  await page.screenshot({ path: 'test-results/wiki-mobile.png' });
});

test('primary and guide text retain readable contrast', async ({ page }) => {
  await page.goto('guides.html#hospitality');
  const contrast = await page.locator('#hospitality .guide-lead').evaluate(el => {
    const rgb = value => value.match(/[\d.]+/g).slice(0, 3).map(Number).map(n => n / 255);
    const lum = value => rgb(value).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4).reduce((s, n, i) => s + n * [.2126, .7152, .0722][i], 0);
    const text = lum(getComputedStyle(el).color), background = lum(getComputedStyle(document.body).backgroundColor);
    return (Math.max(text, background) + .05) / (Math.min(text, background) + .05);
  });
  expect(contrast).toBeGreaterThanOrEqual(4.5);
});

test('published pages retain the original NHN theme and load CSS from the root artifact', async ({ page, request }) => {
  const sheet = await request.get('assets/style.css');
  expect(sheet.status()).toBe(200);
  const css = await sheet.text();
  expect(css).toContain('--bg:#0b1214');
  expect(css).toContain('fonts.googleapis.com/css2?family=Manrope');
  for (const route of ['./', 'wiki.html', 'guides.html', 'updates.html']) {
    await page.goto(route);
    const theme = await page.evaluate(() => {
      const body = getComputedStyle(document.body);
      const title = getComputedStyle(document.querySelector('h1'));
      return {
        background: body.backgroundColor,
        font: body.fontFamily,
        titleFont: title.fontFamily,
        link: document.querySelector('link[rel="stylesheet"]')?.getAttribute('href'),
        sheets: document.styleSheets.length,
      };
    });
    expect(theme.background).toBe('rgb(11, 18, 20)');
    expect(theme.font).toContain('Manrope');
    expect(theme.titleFont).toContain('Playfair Display');
    expect(theme.link).toBe('assets/style.css');
    expect(theme.sheets).toBeGreaterThan(0);
  }
});
