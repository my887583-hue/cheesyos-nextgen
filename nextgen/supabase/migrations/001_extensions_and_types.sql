-- CHEESYOS NEXTGEN V1 MIGRATION: 001_extensions_and_types.sql
-- Target Project: sdbnibyzqtgpbexlznat (NextGen Supabase Dev)
-- Status: GENERATED_NOT_APPLIED

-- Enable required PostgreSQL extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Reusable automatic updated_at timestamp trigger function
CREATE OR REPLACE FUNCTION public.trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
