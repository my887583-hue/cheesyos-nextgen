/**
 * CHEESYOS NEXTGEN — AUTH & ACCESS MODEL CONTRACTS
 * Shared authorization and identity access flags for V1 applications.
 * 
 * Authorities:
 * - Supabase Auth (auth.users) = Authentication authority.
 * - staff_profiles = Staff authorization profile (auth.users.id == staff_profiles.id).
 * - customers = Customer profile (auth.users.id == customers.id).
 */

export const APP_ACCESS_FLAGS = {
  POS_ACCESS: 'has_pos_access',
  ADMIN_ACCESS: 'has_admin_access',
} as const;

export type AppAccessFlag = typeof APP_ACCESS_FLAGS[keyof typeof APP_ACCESS_FLAGS];

export interface AppAccessState {
  userId: string;
  hasPosAccess: boolean;
  hasAdminAccess: boolean;
  role: 'cashier' | 'manager' | 'admin' | 'owner';
  isActive: boolean;
}

/**
 * Validates whether a staff access profile permits POS operation.
 */
export function canAccessPos(accessState: AppAccessState | null | undefined): boolean {
  if (!accessState) return false;
  return accessState.isActive && accessState.hasPosAccess;
}

/**
 * Validates whether a staff access profile permits Admin operation.
 */
export function canAccessAdmin(accessState: AppAccessState | null | undefined): boolean {
  if (!accessState) return false;
  return accessState.isActive && accessState.hasAdminAccess;
}
