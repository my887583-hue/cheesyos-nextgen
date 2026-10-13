import React, { useEffect, useState, useCallback, useMemo } from 'react';
import type {
  IPosPersistence,
  PosCatalog,
  CategoryCatalogDomain,
  ProductCatalogDomain,
  ProductVariantCatalogDomain,
} from '@cheesyos/pos-local';

export function formatPaise(paise: number): string {
  const rupees = (paise / 100).toFixed(2);
  return `₹${rupees}`;
}

export interface MenuCatalogProps {
  db: IPosPersistence;
  initialCatalog?: PosCatalog;
  selectedProductId?: string | null;
  onSelectProduct?: (product: ProductCatalogDomain) => void;
  onAddToCart?: (product: ProductCatalogDomain, variant?: ProductVariantCatalogDomain | null) => void;
  isReadOnly?: boolean;
}

export function MenuCatalog({
  db,
  initialCatalog,
  selectedProductId,
  onSelectProduct,
  onAddToCart,
  isReadOnly = false,
}: MenuCatalogProps): React.ReactElement {
  const [catalog, setCatalog] = useState<PosCatalog | null>(initialCatalog || null);
  const [loading, setLoading] = useState(initialCatalog ? false : true);
  const [error, setError] = useState<string | null>(null);
  const [selectedCategoryId, setSelectedCategoryId] = useState<string>('ALL');

  /**
   * Loads catalog authoritatively from local SQLite persistence.
   * Demand-driven: zero background polling timers.
   */
  const loadCatalog = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await db.getCatalog();
      setCatalog(data);
    } catch (err: any) {
      setError('Failed to load menu catalog from local storage.');
    } finally {
      setLoading(false);
    }
  }, [db]);

  useEffect(() => {
    if (!initialCatalog) {
      loadCatalog();
    }
  }, [initialCatalog, loadCatalog]);

  // Active categories sorted by display order
  const activeCategories = useMemo(() => {
    if (!catalog?.categories) return [];
    return catalog.categories
      .filter((c) => c.is_active)
      .sort((a, b) => (a.display_order ?? 0) - (b.display_order ?? 0));
  }, [catalog]);

  // Group variants by product_id
  const variantsByProductId = useMemo(() => {
    const map = new Map<string, ProductVariantCatalogDomain[]>();
    if (!catalog?.variants) return map;
    for (const v of catalog.variants) {
      if (!map.has(v.product_id)) {
        map.set(v.product_id, []);
      }
      map.get(v.product_id)!.push(v);
    }
    return map;
  }, [catalog]);

  // Filter products by selected category
  const filteredProducts = useMemo(() => {
    if (!catalog?.products) return [];
    if (selectedCategoryId === 'ALL') {
      return catalog.products;
    }
    return catalog.products.filter((p) => p.category_id === selectedCategoryId);
  }, [catalog, selectedCategoryId]);

  // Category lookup map
  const categoryMap = useMemo(() => {
    const map = new Map<string, string>();
    if (!catalog?.categories) return map;
    for (const c of catalog.categories) {
      map.set(c.id, c.name);
    }
    return map;
  }, [catalog]);

  if (loading && !catalog) {
    return (
      <div
        id="catalog-loading"
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          height: '300px',
          color: '#64748b',
          fontSize: '15px',
        }}
      >
        Loading menu catalog...
      </div>
    );
  }

  if (error && !catalog) {
    return (
      <div
        id="catalog-error"
        style={{
          backgroundColor: '#fef2f2',
          border: '1px solid #fecaca',
          color: '#991b1b',
          padding: '16px',
          borderRadius: '8px',
          margin: '20px',
          fontSize: '14px',
        }}
      >
        {error}
      </div>
    );
  }

  const allProductsCount = catalog?.products?.length || 0;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
      {/* Category Navigation Bar */}
      <nav
        id="category-nav"
        aria-label="Menu Categories"
        style={{
          display: 'flex',
          gap: '8px',
          padding: '12px 16px',
          backgroundColor: '#ffffff',
          borderBottom: '1px solid #e2e8f0',
          overflowX: 'auto',
          whiteSpace: 'nowrap',
          alignItems: 'center',
        }}
      >
        <button
          type="button"
          id="category-tab-all"
          onClick={() => setSelectedCategoryId('ALL')}
          style={{
            backgroundColor: selectedCategoryId === 'ALL' ? '#0284c7' : '#f8fafc',
            color: selectedCategoryId === 'ALL' ? '#ffffff' : '#334155',
            border: selectedCategoryId === 'ALL' ? '1px solid #0284c7' : '1px solid #cbd5e1',
            padding: '6px 14px',
            borderRadius: '6px',
            fontSize: '13px',
            fontWeight: '600',
            cursor: 'pointer',
            transition: 'all 0.15s',
          }}
        >
          {`All Items (${allProductsCount})`}
        </button>

        {activeCategories.map((cat) => {
          const isSelected = selectedCategoryId === cat.id;
          const count = catalog?.products.filter((p) => p.category_id === cat.id).length || 0;
          return (
            <button
              key={cat.id}
              type="button"
              id={`category-tab-${cat.slug || cat.id}`}
              onClick={() => setSelectedCategoryId(cat.id)}
              style={{
                backgroundColor: isSelected ? '#0284c7' : '#f8fafc',
                color: isSelected ? '#ffffff' : '#334155',
                border: isSelected ? '1px solid #0284c7' : '1px solid #cbd5e1',
                padding: '6px 14px',
                borderRadius: '6px',
                fontSize: '13px',
                fontWeight: '600',
                cursor: 'pointer',
                transition: 'all 0.15s',
              }}
            >
              {`${cat.name} (${count})`}
            </button>
          );
        })}
      </nav>

      {/* Catalog Empty State */}
      {filteredProducts.length === 0 && (
        <div
          id="catalog-empty"
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            height: '240px',
            color: '#64748b',
            fontSize: '14px',
          }}
        >
          No products found in this category.
        </div>
      )}

      {/* Products Grid */}
      <div
        id="product-grid"
        style={{
          flex: 1,
          padding: '16px',
          overflowY: 'auto',
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(210px, 1fr))',
          gap: '14px',
          alignContent: 'start',
        }}
      >
        {filteredProducts.map((product) => {
          const variants = variantsByProductId.get(product.id) || [];
          const categoryName = categoryMap.get(product.category_id) || 'General';
          const isSelected = selectedProductId === product.id;
          const canAddSimple = !isReadOnly && product.is_available && variants.length === 0;

          return (
            <div
              key={product.id}
              id={`product-card-${product.id}`}
              onClick={() => onSelectProduct?.(product)}
              style={{
                backgroundColor: '#ffffff',
                border: isSelected ? '2px solid #0284c7' : '1px solid #e2e8f0',
                borderRadius: '8px',
                padding: '14px',
                display: 'flex',
                flexDirection: 'column',
                justifyContent: 'space-between',
                boxShadow: isSelected ? '0 0 0 2px #0284c7' : '0 1px 2px rgba(0,0,0,0.04)',
                cursor: isReadOnly ? 'default' : 'pointer',
                opacity: product.is_available ? 1 : 0.6,
                transition: 'all 0.15s ease-in-out',
              }}
            >
              <div>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: '8px', marginBottom: '6px' }}>
                  <h4 style={{ margin: 0, fontSize: '15px', fontWeight: '700', color: '#0f172a' }}>
                    {product.name}
                  </h4>
                  <span
                    style={{
                      fontSize: '10px',
                      fontWeight: '700',
                      textTransform: 'uppercase',
                      padding: '2px 6px',
                      borderRadius: '4px',
                      backgroundColor: product.is_available ? '#ecfdf5' : '#fef2f2',
                      color: product.is_available ? '#047857' : '#b91c1c',
                    }}
                  >
                    {product.is_available ? 'Available' : 'Unavailable'}
                  </span>
                </div>

                <div style={{ fontSize: '11px', color: '#64748b', marginBottom: '8px' }}>
                  {categoryName}
                </div>

                {product.description && (
                  <p style={{ margin: '0 0 8px 0', fontSize: '12px', color: '#64748b', lineHeight: '1.4' }}>
                    {product.description}
                  </p>
                )}
              </div>

              <div>
                {/* Product Variants (if present) */}
                {variants.length > 0 ? (
                  <div
                    id={`product-variants-${product.id}`}
                    style={{
                      borderTop: '1px dashed #e2e8f0',
                      paddingTop: '8px',
                      marginTop: '8px',
                      marginBottom: '8px',
                      display: 'flex',
                      flexDirection: 'column',
                      gap: '4px',
                    }}
                  >
                    <div style={{ fontSize: '11px', fontWeight: '600', color: '#475569' }}>
                      Variants:
                    </div>
                    {variants.map((v) => {
                      const variantPrice =
                        v.price_override_paise !== null ? v.price_override_paise : product.base_price_paise;
                      const canAddVariant = !isReadOnly && product.is_available && v.is_available;
                      return (
                        <div
                          key={v.id}
                          id={`variant-item-${v.id}`}
                          style={{
                            display: 'flex',
                            justifyContent: 'space-between',
                            alignItems: 'center',
                            fontSize: '12px',
                            color: '#334155',
                            padding: '2px 0',
                          }}
                        >
                          <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                            <span>{v.variant_name}</span>
                            {!v.is_available && (
                              <span style={{ fontSize: '9px', color: '#ef4444' }}>(Out of stock)</span>
                            )}
                          </div>
                          <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                            <span style={{ fontWeight: '600' }}>{formatPaise(variantPrice)}</span>
                            {onAddToCart && (
                              <button
                                type="button"
                                id={`add-variant-${v.id}`}
                                disabled={!canAddVariant}
                                onClick={(e) => {
                                  e.stopPropagation();
                                  onAddToCart(product, v);
                                }}
                                style={{
                                  backgroundColor: !canAddVariant ? '#cbd5e1' : '#0284c7',
                                  color: '#ffffff',
                                  border: 'none',
                                  padding: '3px 8px',
                                  borderRadius: '4px',
                                  fontSize: '11px',
                                  fontWeight: '700',
                                  cursor: !canAddVariant ? 'not-allowed' : 'pointer',
                                }}
                              >
                                + Add
                              </button>
                            )}
                          </div>
                        </div>
                      );
                    })}
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: '6px' }}>
                      <span style={{ fontSize: '11px', color: '#64748b' }}>Base Price</span>
                      <span id={`product-price-${product.id}`} style={{ fontSize: '13px', fontWeight: '600', color: '#64748b' }}>
                        {formatPaise(product.base_price_paise)}
                      </span>
                    </div>
                  </div>
                ) : (
                  /* Simple Product Price & Add Button */
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: '6px' }}>
                    <div>
                      <span style={{ fontSize: '11px', color: '#64748b', display: 'block' }}>Price</span>
                      <span
                        id={`product-price-${product.id}`}
                        style={{ fontSize: '16px', fontWeight: '700', color: '#0f172a' }}
                      >
                        {formatPaise(product.base_price_paise)}
                      </span>
                    </div>
                    {onAddToCart && (
                      <button
                        type="button"
                        id={`add-product-${product.id}`}
                        disabled={!canAddSimple}
                        onClick={(e) => {
                          e.stopPropagation();
                          onAddToCart(product, null);
                        }}
                        style={{
                          backgroundColor: !canAddSimple ? '#cbd5e1' : '#0284c7',
                          color: '#ffffff',
                          border: 'none',
                          padding: '6px 14px',
                          borderRadius: '6px',
                          fontSize: '13px',
                          fontWeight: '700',
                          cursor: !canAddSimple ? 'not-allowed' : 'pointer',
                          transition: 'background 0.15s',
                        }}
                      >
                        + Add
                      </button>
                    )}
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export default MenuCatalog;
