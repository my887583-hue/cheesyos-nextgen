-- CHEESYOS NEXTGEN V1 MIGRATION: 008_device_identity_and_terminal_registry.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: GENERATED_FOR_PHASE_3F_1
-- Core Objective: Minimal POS Device/Terminal Identity & Revocation Authority

-- ============================================================================
-- 1. POS DEVICES CLOUD REGISTRY TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.pos_devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  terminal_code TEXT NOT NULL,
  device_name TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ NULL,

  -- Enforce uniqueness on terminal_code
  CONSTRAINT uq_pos_devices_terminal_code UNIQUE (terminal_code),

  -- Enforce non-empty normalized terminal_code format (e.g. T01, T02, POS-01)
  CONSTRAINT chk_pos_devices_terminal_code_format CHECK (
    length(trim(terminal_code)) >= 2 AND terminal_code ~ '^[A-Za-z0-9_-]+$'
  ),

  -- Revocation invariant: if revoked, is_active must be false and revoked_at set
  CONSTRAINT chk_pos_devices_revocation CHECK (
    (is_active = true AND revoked_at IS NULL) OR (is_active = false)
  )
);

-- Index for terminal lookup
CREATE INDEX IF NOT EXISTS idx_pos_devices_terminal_code ON public.pos_devices (terminal_code);

-- ============================================================================
-- 2. ENABLE RLS & ROW ACCESS POLICIES
-- ============================================================================

ALTER TABLE public.pos_devices ENABLE ROW LEVEL SECURITY;

-- POS / Admin Staff Read Policy (Active devices only)
CREATE POLICY "POS staff read active devices" ON public.pos_devices
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.staff_profiles
      WHERE id = auth.uid()
        AND (has_pos_access = true OR has_admin_access = true)
        AND is_active = true
    )
    AND is_active = true
  );

-- Admin Full Management Policy (Read, Create, Update, Revoke)
CREATE POLICY "Admin full manage devices" ON public.pos_devices
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.staff_profiles
      WHERE id = auth.uid()
        AND has_admin_access = true
        AND is_active = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.staff_profiles
      WHERE id = auth.uid()
        AND has_admin_access = true
        AND is_active = true
    )
  );

-- Grants
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pos_devices TO authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON public.pos_devices TO service_role;
  END IF;
END $$;

