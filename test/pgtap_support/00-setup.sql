CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgtap;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'geo_genius') THEN
    RAISE EXCEPTION
      'geo_genius schema is not installed; run: mix test test/geo_genius/migration_test.exs';
  END IF;
END;
$$;
