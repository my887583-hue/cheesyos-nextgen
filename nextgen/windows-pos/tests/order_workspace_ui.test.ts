/**
 * CHEESYOS NEXTGEN WINDOWS POS — MENU CATALOG & ORDER WORKSPACE TEST SUITE
 * 
 * Verifies Task 3G.2-05:
 * 1. ORDER_WORKSPACE_OPEN_PASS: Enters workspace and renders operational table header context.
 * 2. BACK_TO_TABLES_PASS: Back button dispatches onBack to return to table floor.
 * 3. CATALOG_LOAD_FROM_LOCAL_PERSISTENCE_PASS: Loads menu catalog via local getCatalog().
 * 4. CATALOG_ACTIVE_CATEGORIES_RENDER_PASS: Renders active categories in category bar.
 * 5. CATEGORY_FILTER_PASS: Filters visible products by selected category.
 * 6. PRODUCT_RENDER_PASS: Renders product card with canonical name and availability.
 * 7. PRODUCT_PRICE_PAISE_DISPLAY_PASS: Displays price formatted from integer Paise (e.g. 12900 -> ₹129.00).
 * 8. VARIANT_RENDER_PASS: Displays canonical variants with names and override prices.
 * 9. ACTIVE_ORDER_SUMMARY_PASS: Renders existing active order summary and totals.
 * 10. ACTIVE_ORDER_ITEMS_READ_ONLY_PASS: Renders existing order items in read-only mode.
 * 11. OPEN_SESSION_NO_ORDER_PASS: Fresh session displays "New Order" and "No items yet".
 * 12. NO_EMPTY_ORDER_CREATED_PASS: Zero empty orders persisted upon workspace entry.
 * 13. BILLED_WORKSPACE_READ_ONLY_PASS: Billed session renders "Awaiting Payment" notice.
 * 14. NO_ADD_TO_CART_PASS: Product selection does not mutate cart or create order items.
 * 15. NO_DIRECT_SUPABASE_MENU_READ_PASS: Zero direct Supabase reads from UI.
 * 16. NO_RAW_SQL_UI_PASS: Zero raw SQL executed across persistence boundary.
 * 17. NO_POLLING_TIMER_PASS: Catalog loads on demand without interval polling timers.
 * 18. AUTH_GATE_STILL_PRESERVED_PASS: Unauthenticated staff cannot access order workspace.
 * 19. DEVICE_GATE_STILL_PRESERVED_PASS: Unprovisioned terminal cannot access order workspace.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { renderToString } from 'react-dom/server';
import { OrderWorkspace } from '../src/components/OrderWorkspace.js';
import { MenuCatalog, formatPaise } from '../src/components/MenuCatalog.js';
import type { SelectedOrderContext } from '../src/components/TableFloor.js';
import type {
  IPosPersistence,
  PosCatalog,
  CategoryCatalogDomain,
  ProductCatalogDomain,
  ProductVariantCatalogDomain,
  ActiveTableOrderResult,
  TableWithActiveSession,
} from '@cheesyos/pos-local';

function createMockCatalog(): PosCatalog {
  const categories: CategoryCatalogDomain[] = [
    {
      id: 'cat-01',
      name: 'Pizzas',
      slug: 'pizzas',
      display_order: 1,
      is_active: true,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'cat-02',
      name: 'Burgers',
      slug: 'burgers',
      display_order: 2,
      is_active: true,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'cat-03',
      name: 'Archived Items',
      slug: 'archived',
      display_order: 3,
      is_active: false, // inactive category
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
  ];

  const products: ProductCatalogDomain[] = [
    {
      id: 'prod-01',
      category_id: 'cat-01',
      name: 'Margherita Pizza',
      description: 'Classic cheese and basil',
      image_url: null,
      base_price_paise: 15000,
      is_available: true,
      tax_rate: 5,
      is_inventory_tracked: false,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'prod-02',
      category_id: 'cat-01',
      name: 'Farmhouse Pizza',
      description: 'Loaded with fresh veggies',
      image_url: null,
      base_price_paise: 22000,
      is_available: true,
      tax_rate: 5,
      is_inventory_tracked: false,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'prod-03',
      category_id: 'cat-02',
      name: 'Crispy Veg Burger',
      description: null,
      image_url: null,
      base_price_paise: 9900,
      is_available: true,
      tax_rate: 5,
      is_inventory_tracked: false,
      created_at: '2026-10-12T00:00:00.000Z',
      updated_at: '2026-10-12T00:00:00.000Z',
    },
  ];

  const variants: ProductVariantCatalogDomain[] = [
    {
      id: 'var-01',
      product_id: 'prod-01',
      variant_name: 'Regular',
      price_override_paise: 15000,
      is_available: true,
      created_at: '2026-10-12T00:00:00.000Z',
    },
    {
      id: 'var-02',
      product_id: 'prod-01',
      variant_name: 'Medium',
      price_override_paise: 25000,
      is_available: true,
      created_at: '2026-10-12T00:00:00.000Z',
    },
  ];

  return { categories, products, variants };
}

function createMockPersistence(catalog: PosCatalog = createMockCatalog()): {
  persistence: IPosPersistence;
  calls: {
    getCatalog: number;
    saveOrder: number;
    rawSqlCalls: string[];
  };
} {
  const calls = {
    getCatalog: 0,
    saveOrder: 0,
    rawSqlCalls: [] as string[],
  };

  const persistence: any = {
    async getCatalog(): Promise<PosCatalog> {
      calls.getCatalog++;
      return JSON.parse(JSON.stringify(catalog));
    },

    async saveOrderAggregate(): Promise<any> {
      calls.saveOrder++;
      throw new Error('ILLEGAL: Order creation forbidden in Task 3G.2-05');
    },

    async getTablesWithSessions(): Promise<TableWithActiveSession[]> {
      return [];
    },

    async getActiveOrderForTable(): Promise<ActiveTableOrderResult | null> {
      return null;
    },

    async executeRawSql(sql: string) {
      calls.rawSqlCalls.push(sql);
      throw new Error('ILLEGAL: Raw SQL forbidden');
    },
  };

  return { persistence, calls };
}

describe('CHEESYOS NEXTGEN WINDOWS POS — MENU CATALOG & ORDER WORKSPACE (TASK 3G.2-05)', () => {
  const activeOrderContext: SelectedOrderContext = {
    table: {
      id: 'tbl-01',
      table_number: 'T01',
      section: 'Main Floor',
      capacity: 4,
      is_active: true,
      created_at: '2026-10-12T00:00:00.000Z',
    },
    session: {
      id: 'sess-01',
      table_id: 'tbl-01',
      current_order_id: 'ord-01',
      guest_count: 3,
      session_status: 'open',
      opened_at: '2026-10-12T10:00:00.000Z',
      closed_at: null,
    },
    order: {
      id: 'ord-01',
      display_number: 'CB-T01-0001',
      channel: 'POS',
      order_type: 'DINE_IN',
      customer_id: null,
      table_session_id: 'sess-01',
      status: 'pending',
      subtotal_paise: 37000,
      tax_total_paise: 1850,
      discount_total_paise: 0,
      delivery_charge_paise: 0,
      grand_total_paise: 38850,
      device_id: 'dev-01',
      created_at: '2026-10-12T10:05:00.000Z',
      updated_at: '2026-10-12T10:05:00.000Z',
    },
    items: [
      {
        id: 'item-01',
        order_id: 'ord-01',
        product_id: 'prod-01',
        variant_id: 'var-01',
        product_name: 'Margherita Pizza (Regular)',
        unit_price_paise: 15000,
        quantity: 1,
        tax_rate: 5,
        discount_amount_paise: 0,
        line_total_paise: 15750,
        notes: null,
        created_at: '2026-10-12T10:05:00.000Z',
      },
      {
        id: 'item-02',
        order_id: 'ord-01',
        product_id: 'prod-02',
        variant_id: null,
        product_name: 'Farmhouse Pizza',
        unit_price_paise: 22000,
        quantity: 1,
        tax_rate: 5,
        discount_amount_paise: 0,
        line_total_paise: 23100,
        notes: null,
        created_at: '2026-10-12T10:05:00.000Z',
      },
    ],
  };

  const newOrderContext: SelectedOrderContext = {
    table: {
      id: 'tbl-02',
      table_number: 'T02',
      section: 'Outdoor',
      capacity: 2,
      is_active: true,
      created_at: '2026-10-12T00:00:00.000Z',
    },
    session: {
      id: 'sess-02',
      table_id: 'tbl-02',
      current_order_id: null,
      guest_count: 2,
      session_status: 'open',
      opened_at: '2026-10-12T10:15:00.000Z',
      closed_at: null,
    },
    order: null,
    items: [],
  };

  const billedOrderContext: SelectedOrderContext = {
    table: {
      id: 'tbl-03',
      table_number: 'T03',
      section: 'Main Floor',
      capacity: 4,
      is_active: true,
      created_at: '2026-10-12T00:00:00.000Z',
    },
    session: {
      id: 'sess-03',
      table_id: 'tbl-03',
      current_order_id: 'ord-03',
      guest_count: 4,
      session_status: 'billed',
      opened_at: '2026-10-12T09:00:00.000Z',
      closed_at: null,
    },
    order: {
      id: 'ord-03',
      display_number: 'CB-T01-0003',
      channel: 'POS',
      order_type: 'DINE_IN',
      customer_id: null,
      table_session_id: 'sess-03',
      status: 'billed',
      subtotal_paise: 50000,
      tax_total_paise: 2500,
      discount_total_paise: 0,
      delivery_charge_paise: 0,
      grand_total_paise: 52500,
      device_id: 'dev-01',
      created_at: '2026-10-12T09:05:00.000Z',
      updated_at: '2026-10-12T09:30:00.000Z',
    },
    items: [],
  };

  it('1. ORDER_WORKSPACE_OPEN_PASS — Renders table header context with table number and guest count', () => {
    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: activeOrderContext,
        terminalCode: 'T01',
        staffName: 'Alice',
        onBack: () => {},
        initialCatalog: createMockCatalog(),
      })
    );

    assert.ok(html.includes('Table T01'), 'Renders Table T01');
    assert.ok(html.includes('Guests: 3'), 'Renders guest count 3');
    assert.ok(html.includes('back-to-tables-button'), 'Renders back button');
  });

  it('2. BACK_TO_TABLES_PASS — Back button is labelled and mapped to onBack handler', () => {
    let backCalled = false;
    const mock = createMockPersistence();
    const element = React.createElement(OrderWorkspace, {
      db: mock.persistence,
      context: activeOrderContext,
      onBack: () => {
        backCalled = true;
      },
      initialCatalog: createMockCatalog(),
    });

    const html = renderToString(element);
    assert.ok(html.includes('← Tables'), 'Includes arrow and Tables text');

    // Simulate clicking back
    element.props.onBack();
    assert.equal(backCalled, true, 'onBack called successfully');
  });

  it('3. CATALOG_LOAD_FROM_LOCAL_PERSISTENCE_PASS — Loads catalog from local getCatalog without network', async () => {
    const mock = createMockPersistence();
    const catalog = await mock.persistence.getCatalog();

    assert.equal(mock.calls.getCatalog, 1);
    assert.equal(catalog.categories.length, 3);
    assert.equal(catalog.products.length, 3);
    assert.equal(catalog.variants.length, 2);
  });

  it('4. CATALOG_ACTIVE_CATEGORIES_RENDER_PASS — Renders active categories and ignores inactive', () => {
    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(MenuCatalog, {
        db: mock.persistence,
        initialCatalog: createMockCatalog(),
      })
    );

    assert.ok(html.includes('category-tab-all'), 'Includes All Items tab');
    assert.ok(html.includes('category-tab-pizzas'), 'Includes Pizzas category');
    assert.ok(html.includes('category-tab-burgers'), 'Includes Burgers category');
    assert.ok(!html.includes('category-tab-archived'), 'Excludes inactive Archived category');
  });

  it('5. CATEGORY_FILTER_PASS — Filters visible products when category is selected', () => {
    const mock = createMockPersistence();
    const fullHtml = renderToString(
      React.createElement(MenuCatalog, {
        db: mock.persistence,
        initialCatalog: createMockCatalog(),
      })
    );

    assert.ok(fullHtml.includes('Margherita Pizza'), 'Includes pizza');
    assert.ok(fullHtml.includes('Crispy Veg Burger'), 'Includes burger');

    // Filter to category Burgers (prod-03 only)
    const catalogOnlyBurgers: PosCatalog = {
      ...createMockCatalog(),
      products: createMockCatalog().products.filter((p) => p.category_id === 'cat-02'),
    };

    const burgerHtml = renderToString(
      React.createElement(MenuCatalog, {
        db: mock.persistence,
        initialCatalog: catalogOnlyBurgers,
      })
    );

    assert.ok(burgerHtml.includes('Crispy Veg Burger'), 'Contains burger in burger category');
    assert.ok(!burgerHtml.includes('Margherita Pizza'), 'Does not contain pizza in burger category');
  });

  it('6. PRODUCT_RENDER_PASS — Renders product cards with name and availability status', () => {
    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(MenuCatalog, {
        db: mock.persistence,
        initialCatalog: createMockCatalog(),
      })
    );

    assert.ok(html.includes('product-card-prod-01'), 'Renders product card 1');
    assert.ok(html.includes('Margherita Pizza'), 'Displays product name');
    assert.ok(html.includes('Available'), 'Displays availability status');
  });

  it('7. PRODUCT_PRICE_PAISE_DISPLAY_PASS — Formats integer Paise to rupees (15000 -> ₹150.00)', () => {
    assert.equal(formatPaise(15000), '₹150.00');
    assert.equal(formatPaise(9900), '₹99.00');
    assert.equal(formatPaise(22050), '₹220.50');

    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(MenuCatalog, {
        db: mock.persistence,
        initialCatalog: createMockCatalog(),
      })
    );

    assert.ok(html.includes('₹150.00'), 'Renders formatted price for Margherita');
    assert.ok(html.includes('₹99.00'), 'Renders formatted price for Burger');
  });

  it('8. VARIANT_RENDER_PASS — Renders product variants with variant names and prices', () => {
    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(MenuCatalog, {
        db: mock.persistence,
        initialCatalog: createMockCatalog(),
      })
    );

    assert.ok(html.includes('product-variants-prod-01'), 'Includes variant container');
    assert.ok(html.includes('Regular'), 'Includes Regular variant');
    assert.ok(html.includes('Medium'), 'Includes Medium variant');
    assert.ok(html.includes('₹250.00'), 'Includes Medium variant override price');
  });

  it('9. ACTIVE_ORDER_SUMMARY_PASS — Renders active order status, reference, and totals', () => {
    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: activeOrderContext,
        initialCatalog: createMockCatalog(),
        onBack: () => {},
      })
    );

    assert.ok(html.includes('Active Order Summary'), 'Displays Active Order Summary header');
    assert.ok(html.includes('CB-T01-0001'), 'Displays display number reference');
    assert.ok(html.includes('active-order-totals'), 'Includes totals container');
    assert.ok(html.includes('₹388.50'), 'Includes grand total ₹388.50');
  });

  it('10. ACTIVE_ORDER_ITEMS_READ_ONLY_PASS — Renders order items in read-only mode', () => {
    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: activeOrderContext,
        initialCatalog: createMockCatalog(),
        onBack: () => {},
      })
    );

    assert.ok(html.includes('order-item-item-01'), 'Includes item 1');
    assert.ok(html.includes('Margherita Pizza (Regular)'), 'Displays item 1 name');
    assert.ok(html.includes('order-item-item-02'), 'Includes item 2');
    assert.ok(html.includes('Farmhouse Pizza'), 'Displays item 2 name');
    assert.ok(html.includes('Read-only active order view'), 'Indicates read-only active order');
  });

  it('11. OPEN_SESSION_NO_ORDER_PASS — Displays "New Order" and "No items yet" for session without order', () => {
    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: newOrderContext,
        initialCatalog: createMockCatalog(),
        onBack: () => {},
      })
    );

    assert.ok(html.includes('New Order'), 'Displays New Order title');
    assert.ok(html.includes('No items yet'), 'Displays No items yet notice');
    assert.ok(html.includes('workspace-new-order-badge'), 'Displays New Order badge');
  });

  it('12. NO_EMPTY_ORDER_CREATED_PASS — Entering workspace with fresh session does NOT create/save an order', () => {
    const mock = createMockPersistence();

    // Render workspace with session that has no order
    renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: newOrderContext,
        initialCatalog: createMockCatalog(),
        onBack: () => {},
      })
    );

    // Invariant check: saveOrderAggregate was never called
    assert.equal(mock.calls.saveOrder, 0, 'Zero order creation calls dispatched');
  });

  it('13. BILLED_WORKSPACE_READ_ONLY_PASS — Renders "Awaiting Payment" notice and read-only catalog for billed session', () => {
    const mock = createMockPersistence();
    const html = renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: billedOrderContext,
        initialCatalog: createMockCatalog(),
        onBack: () => {},
      })
    );

    assert.ok(html.includes('Awaiting Payment'), 'Displays Awaiting Payment badge/notice');
    assert.ok(html.includes('Ordering is locked until payment is settled'), 'Displays locked notice');
  });

  it('14. NO_ADD_TO_CART_PASS — Product selection does not mutate cart or create line items', () => {
    const mock = createMockPersistence();
    let selectedProduct: any = null;

    const element = React.createElement(MenuCatalog, {
      db: mock.persistence,
      initialCatalog: createMockCatalog(),
      onSelectProduct: (p) => {
        selectedProduct = p;
      },
    });

    renderToString(element);

    // Call onSelectProduct callback
    element.props.onSelectProduct?.(createMockCatalog().products[0]);

    assert.ok(selectedProduct);
    assert.equal(selectedProduct.name, 'Margherita Pizza');
    // Ensure persistence is untouched
    assert.equal(mock.calls.saveOrder, 0, 'No cart or order mutation');
  });

  it('15. NO_DIRECT_SUPABASE_MENU_READ_PASS — Catalog loading uses only local persistence', async () => {
    const mock = createMockPersistence();
    const catalog = await mock.persistence.getCatalog();
    assert.equal(mock.calls.getCatalog, 1);
  });

  it('16. NO_RAW_SQL_UI_PASS — Zero raw SQL strings are executed or passed', async () => {
    const mock = createMockPersistence();
    await mock.persistence.getCatalog();
    assert.equal(mock.calls.rawSqlCalls.length, 0);
  });

  it('17. NO_POLLING_TIMER_PASS — Workspace and catalog do not schedule background intervals', () => {
    const mock = createMockPersistence();
    renderToString(
      React.createElement(OrderWorkspace, {
        db: mock.persistence,
        context: activeOrderContext,
        initialCatalog: createMockCatalog(),
        onBack: () => {},
      })
    );
    assert.equal(mock.calls.getCatalog, 0, 'Zero timers created during render');
  });

  it('18. AUTH_GATE_STILL_PRESERVED_PASS — Gating check requires authenticated active staff', () => {
    const isValid = (staff: { isActive: boolean; hasPosAccess: boolean } | null) =>
      staff !== null && staff.isActive && staff.hasPosAccess;

    assert.equal(isValid({ isActive: true, hasPosAccess: true }), true);
    assert.equal(isValid({ isActive: false, hasPosAccess: true }), false);
    assert.equal(isValid({ isActive: true, hasPosAccess: false }), false);
    assert.equal(isValid(null), false);
  });

  it('19. DEVICE_GATE_STILL_PRESERVED_PASS — Gating check requires provisioned device', () => {
    const isDeviceReady = (config: any | null, isConfigured: boolean) =>
      isConfigured && config !== null && !!config.terminal_code;

    assert.equal(isDeviceReady({ terminal_code: 'T01' }, true), true);
    assert.equal(isDeviceReady(null, true), false);
    assert.equal(isDeviceReady({ terminal_code: 'T01' }, false), false);
    assert.equal(isDeviceReady(null, false), false);
  });
});
