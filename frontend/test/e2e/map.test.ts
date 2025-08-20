/* eslint-disable @stylistic/padded-blocks */

import { expect, test } from '@nuxt/test-utils/playwright'
import * as ApiMocks from './api_mocks'

const ROUTE_MAP_WITH_INVALID_TOKEN = '/map/invalid'
const ROUTE_MAP_WITH_CEC_TOKEN = '/map/cec'
const ROUTE_MAP_WITH_FG_TOKEN = '/map/fg'

// Common API mocks

test.beforeEach(async ({ page }) => {

  await page.route('/api/*', async route => await route.abort())

  await page.route('/api/status', async route => await route.fulfill({ json: ApiMocks.API_STATUS }))

  await page.route('/api/bootstrap/*', async route => await route.fulfill({ status: 404 }))
  await page.route('/api/bootstrap/fg?*', async route => await route.fulfill({ json: ApiMocks.API_BOOTSTRAP_FG }))
  await page.route('/api/bootstrap/cec?*', async route => await route.fulfill({ json: ApiMocks.API_BOOTSTRAP_CEC }))

})

// Api down tests

test.describe('when the api is down', () => {

  test.beforeEach(async ({ page }) => {
    await page.route('/api/*', async route => await route.abort())
  })

  test('it throws if an invalid token is used', async ({ goto, page }) => {
    await goto(ROUTE_MAP_WITH_INVALID_TOKEN, { waitUntil: 'hydration' })
    await expect(page.getByText('Oops!')).toBeVisible()
  })

  test('it throws if the cec token is used', async ({ goto, page }) => {
    await goto(ROUTE_MAP_WITH_CEC_TOKEN, { waitUntil: 'hydration' })
    await expect(page.getByText('Oops!')).toBeVisible()
  })

  test('it throws if the fg token is used', async ({ goto, page }) => {
    await goto(ROUTE_MAP_WITH_FG_TOKEN, { waitUntil: 'hydration' })
    await expect(page.getByText('Oops!')).toBeVisible()
  })

})

// Start popup tests

test.describe('when accessing the map while having never accepted the start popup', () => {

  test.beforeEach(async ({ goto }) => {
    await goto(ROUTE_MAP_WITH_FG_TOKEN, { waitUntil: 'hydration' })
  })

  test('it displays the start popup', async ({ page }) => {
    await expect(page.getByText('Carte Fransgenre : Informations')).toBeVisible()
  })

  test('it does not close the popup when clicked outside', async ({ page }) => {
    await page.locator('.p-dialog-mask', { hasText: 'Carte Fransgenre : Informations' }).click({ position: { x: 0, y: 0 } })
    await expect(page.getByText('Carte Fransgenre : Informations')).toBeVisible()
  })

  test('it only allows to close the popup if the switch is toggled', async ({ page }) => {
    await expect(page.locator('#validated_popup')).not.toBeChecked()
    await expect(page.locator('.p-dialog button', { hasText: 'Valider' })).toBeDisabled()
    await page.locator('#validated_popup').check()
    await expect(page.locator('#validated_popup')).toBeChecked()
    await expect(page.locator('.p-dialog button', { hasText: 'Valider' })).toBeEnabled()
  })

  test('it closes the popup and remembers the acceptance when the button is clicked', async ({ page }) => {
    await page.locator('#validated_popup').check()
    await page.locator('.p-dialog button', { hasText: 'Valider' }).click()
    await expect(page.getByText('Carte Fransgenre : Informations')).not.toBeVisible()
    await expect.poll(() => {
      return page.evaluate(() => window.localStorage.getItem('validatedPopup'))
    }).toBe('true')
  })

})

test.describe('when accessing the map after having accepted the start popup', () => {

  test.beforeEach(async ({ page }) => {
    page.addInitScript(() => {
      window.localStorage.setItem('validatedPopup', 'true')
    })
  })

  test('it does not display the start popup using the cec token', async ({ page, goto }) => {
    await goto(ROUTE_MAP_WITH_FG_TOKEN, { waitUntil: 'hydration' })
    await expect(page.getByText('Carte Fransgenre : Informations')).not.toBeVisible()
  })

})

// Invalid token tests

test.describe('when accessing the map using an invalid token', () => {

  test.beforeEach(async ({ goto }) => {
    await goto(ROUTE_MAP_WITH_INVALID_TOKEN, { waitUntil: 'hydration' })
  })

  test('it redirects elsewhere', async ({ page }) => {
    await expect(page).toHaveURL('https://fransgenre.fr/#lien-expire')
  })

})

// CEC token tests

test.describe('when accessing the map using the cec token', () => {

  test.beforeEach(async ({ goto, page }) => {
    await goto(ROUTE_MAP_WITH_CEC_TOKEN, { waitUntil: 'hydration' })
    await page.locator('#validated_popup').check()
    await page.locator('.p-dialog button', { hasText: 'Valider' }).click()
    await expect(page.getByText('Carte Fransgenre : Informations')).not.toBeVisible()
  })

  test('it displays the map', async ({ page }) => {
    await expect(page.locator('#map_container')).toBeVisible()
  })

})

// FG token tests

test.describe('when accessing the map using the fg token', () => {

  test.beforeEach(async ({ goto, page }) => {
    await goto(ROUTE_MAP_WITH_FG_TOKEN, { waitUntil: 'hydration' })
    await page.locator('#validated_popup').check()
    await page.locator('.p-dialog button', { hasText: 'Valider' }).click()
    await expect(page.getByText('Carte Fransgenre : Informations')).not.toBeVisible()
  })

  test('it displays the map', async ({ page }) => {
    await expect(page.locator('#map_container')).toBeVisible()
  })

})
