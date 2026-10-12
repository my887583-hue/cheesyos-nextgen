-- CHEESYOS NEXTGEN V1 MIGRATION: 011_fix_staff_profiles_rls_recursion.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Remediation (Task 10D): Eliminate 42P17 infinite recursion on public.staff_profiles RLS.

-- ============================================================================
-- 1. SECURITY DEFINER ACTIVE ADMIN HELPER FUNCTION
-- ============================================================================
-- Evaluates whether the currently authenticated caller has active admin access.
-- Bypasses caller RLS recursion via SECURITY DEFINER with fixed empty search_path.
-- Does NOT accept caller-controlled UUID; derives identity strictly from auth.uid().

CREATE OR REPLACE FUNCTION public.is_active_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff_profiles
    WHERE id = (SELECT auth.uid())
      AND has_admin_access = true
      AND is_active = true
  );
$$;

-- Privilege Lockdown: Deny PUBLIC execution, grant strictly to authenticated role.
REVOKE EXECUTE ON FUNCTION public.is_active_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_active_admin() TO authenticated;

-- ============================================================================
-- 2. REPLACE RECURSIVE POLICY ON public.staff_profiles
-- ============================================================================
-- Drop recursive 'Admin full manage staff profiles' policy (FOR ALL with self-subquery).
DROP POLICY IF EXISTS "Admin full manage staff profiles" ON public.staff_profiles;

-- Preserve direct self-read policy: "Staff read own profile" (id = auth.uid()) remains active.

-- Admin SELECT: Active admin can read staff profiles for administrative overview.
CREATE POLICY "Admin read all staff profiles" ON public.staff_profiles
  FOR SELECT TO authenticated
  USING (public.is_active_admin());

-- Admin INSERT: Active admin only.
CREATE POLICY "Admin insert staff profiles" ON public.staff_profiles
  FOR INSERT TO authenticated
  WITH CHECK (public.is_active_admin());

-- Admin UPDATE: Active admin only.
CREATE POLICY "Admin update staff profiles" ON public.staff_profiles
  FOR UPDATE TO authenticated
  USING (public.is_active_admin())
  WITH CHECK (public.is_active_admin());

-- Admin DELETE: Active admin only.
CREATE POLICY "Admin delete staff profiles" ON public.staff_profiles
  FOR DELETE TO authenticated
  USING (public.is_active_admin());
