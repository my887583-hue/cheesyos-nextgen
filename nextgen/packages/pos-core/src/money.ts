/**
 * CHEESYOS NEXTGEN POS CORE — MONEY & FINANCIAL ARITHMETIC ENGINE
 * 
 * Deterministic integer minor-units arithmetic (Paise: 1 Rupee = 100 Paise).
 * Eliminates floating-point rounding errors across cart, order, billing, and settlement.
 */

export type MoneyPaise = number; // Integer representation in Paise

/**
 * Converts decimal Rupee value to integer Paise.
 * e.g., 129.00 -> 12900, 99.50 -> 9950, 129.99 -> 12999
 */
export function toPaise(rupees: number): MoneyPaise {
  if (typeof rupees !== 'number' || isNaN(rupees) || !Number.isFinite(rupees)) {
    throw new Error(`[MoneyEngine] Invalid Rupee amount: ${rupees}`);
  }
  return Math.round((rupees + Number.EPSILON) * 100);
}

/**
 * Converts integer Paise to 2-decimal rounded Rupee value.
 * e.g., 12900 -> 129.00, 9950 -> 99.50
 */
export function toRupees(paise: MoneyPaise): number {
  if (typeof paise !== 'number' || isNaN(paise) || !Number.isFinite(paise)) {
    throw new Error(`[MoneyEngine] Invalid Paise amount: ${paise}`);
  }
  if (!Number.isInteger(paise)) {
    paise = Math.round(paise);
  }
  return paise / 100;
}

/**
 * Adds multiple Paise values safely.
 */
export function addPaise(...amounts: MoneyPaise[]): MoneyPaise {
  return amounts.reduce((acc, curr) => {
    if (typeof curr !== 'number' || isNaN(curr) || !Number.isFinite(curr)) {
      throw new Error(`[MoneyEngine] Invalid addition amount: ${curr}`);
    }
    return acc + Math.round(curr);
  }, 0);
}

/**
 * Subtracts b from a in Paise.
 */
export function subPaise(a: MoneyPaise, b: MoneyPaise): MoneyPaise {
  return Math.round(a) - Math.round(b);
}

/**
 * Multiplies Paise by integer quantity.
 */
export function mulPaise(paise: MoneyPaise, quantity: number): MoneyPaise {
  if (!Number.isInteger(quantity) || quantity < 0) {
    throw new Error(`[MoneyEngine] Invalid quantity multiplier: ${quantity}`);
  }
  return Math.round(paise) * quantity;
}

/**
 * Calculates tax or percentage amount in integer Paise.
 * Uses Math.round to resolve sub-paise fractions deterministically.
 */
export function percentagePaise(basePaise: MoneyPaise, ratePercent: number): MoneyPaise {
  if (ratePercent < 0) {
    throw new Error(`[MoneyEngine] Negative tax/discount rate not allowed: ${ratePercent}`);
  }
  return Math.round((Math.round(basePaise) * ratePercent) / 100);
}
